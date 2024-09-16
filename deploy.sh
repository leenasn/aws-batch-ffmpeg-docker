#!/bin/sh

# Build the Docker image
docker build -t ffmpeg-batch:latest .

# Authenticate Docker to ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 243837092821.dkr.ecr.us-east-1.amazonaws.com

# Tag the image
docker tag ffmpeg-batch:latest 243837092821.dkr.ecr.us-east-1.amazonaws.com/ffmpeg-batch:latest

# Push the image to ECR
docker push 243837092821.dkr.ecr.us-east-1.amazonaws.com/ffmpeg-batch:latest
