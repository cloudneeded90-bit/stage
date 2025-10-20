#!/bin/bash
set -euo pipefail

LOG="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

echo "=== DevOps Automated Deployment Script ==="

# ---- 1. COLLECT INPUTS ----
read -p "Git repo URL: " REPO_URL
read -s -p "GitHub Personal Access Token: " PAT; echo
read -p "Branch (default: main): " BRANCH; BRANCH=${BRANCH:-main}
read -p "SSH username: " SSH_USER
read -p "Server IP: " SERVER_IP
read -p "SSH key path: " SSH_KEY
read -p "App internal port: " APP_PORT

# ---- 2. CLONE OR UPDATE REPO ----
REPO_NAME=$(basename "$REPO_URL" .git)
if [ -d "$REPO_NAME" ]; then
  echo "Repo exists. Pulling latest changes..."
  cd "$REPO_NAME" && git pull origin "$BRANCH" && cd ..
else
  echo "Cloning repo..."
  git clone -b "$BRANCH" "https://${PAT}@${REPO_URL#https://}"
fi

# ---- 3. VERIFY DOCKER FILES ----
cd "$REPO_NAME"
if [ ! -f Dockerfile ] && [ ! -f docker-compose.yml ]; then
  echo "Error: No Dockerfile or docker-compose.yml found."; exit 1
fi
cd ..

# ---- 4. TEST SSH CONNECTION ----
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 ${SSH_USER}@${SERVER_IP} "echo 'SSH OK'" || { echo "SSH failed"; exit 1; }

# ---- 5. SETUP REMOTE ENVIRONMENT ----
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ${SSH_USER}@${SERVER_IP} << 'EOF'
set -e
sudo apt update -y
sudo apt install -y docker.io docker-compose nginx
sudo systemctl enable docker --now
sudo systemctl enable nginx --now
EOF

# ---- 6. TRANSFER PROJECT SAFELY (EXCLUDE .git) ----
echo "Transferring project files..."
rsync -avz -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
  --exclude='.git' \
  "$REPO_NAME" ${SSH_USER}@${SERVER_IP}:~/

# ---- 7. DEPLOY APP ----
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ${SSH_USER}@${SERVER_IP} << EOF
set -e
cd "$REPO_NAME"
if [ -f docker-compose.yml ]; then
  sudo docker-compose down
  sudo docker-compose up -d --build
else
  sudo docker rm -f ${REPO_NAME,,} || true
  sudo docker build -t ${REPO_NAME,,} .
  sudo docker run -d -p 5000:${APP_PORT} --name ${REPO_NAME,,} ${REPO_NAME,,}
fi
EOF

# ---- 8. CONFIGURE NGINX (FIXED ESCAPES) ----
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ${SSH_USER}@${SERVER_IP} << EOF
sudo tee /etc/nginx/sites-available/$REPO_NAME.conf > /dev/null <<'NGINXCONF'
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINXCONF
sudo ln -sf /etc/nginx/sites-available/$REPO_NAME.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
EOF

# ---- 9. VALIDATE ----
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ${SSH_USER}@${SERVER_IP} "curl -I http://localhost || echo 'App check failed'"

echo "=== Deployment completed successfully! Logs saved to $LOG ==="
