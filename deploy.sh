#!/bin/sh
echo "Deploying the application..."
echo "Building the Docker image..."
# Build the Docker image
docker build -t ffmpeg-batch:latest .
echo "Authenticating with ECR..."
# Authenticate Docker to ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 243837092821.dkr.ecr.us-east-1.amazonaws.com

echo "Tagging as latest image..."

# Tag the image
docker tag ffmpeg-batch:latest 243837092821.dkr.ecr.us-east-1.amazonaws.com/ffmpeg-batch:latest

echo "Pushing the image to ECR..."
# Push the image to ECR
docker push 243837092821.dkr.ecr.us-east-1.amazonaws.com/ffmpeg-batch:latest

echo "Deploment done!"