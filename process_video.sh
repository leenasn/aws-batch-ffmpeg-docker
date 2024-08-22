#!/bin/sh

input_video=$2
start_time=$3
duration=$4
output_file=$5
s3_bucket=$6
s3_output_path=$7
webhook_url=$8
job_id=$9
srt_file=$10  # Assuming you pass the job ID as the 9th parameter

echo "input_video $2"
echo "start_time $3"
echo "duration $4"
echo "output_file $5"
echo "s3_bucket $6"
echo "s3_output_path $7"
echo "webhook_url $8"
echo "job_id $9"
echo "srt_file $10"

# Download the input video
aws s3 cp $input_video input.mp4

# If SRT file is provided, download it
#if [ ! -z "$srt_file" ]; then
 # aws s3 cp $srt_file subtitles.srt
  #ffmpeg -y -ss $start_time -t $duration -i input.mp4 -vf "subtitles=subtitles.srt" "$output_file"
#else
 # ffmpeg -y -ss $start_time -t $duration -i input.mp4 $output_file
#fi
ffmpeg -y -ss $start_time -t $duration -i input.mp4 $output_file

# Upload the output video to S3
output_s3_url="s3://$s3_bucket/$s3_output_path"
echo "output_s3_url $output_s3_url"
aws s3 cp $output_file $output_s3_url
aws s3api put-object-acl --bucket $s3_bucket --key $s3_output_path --acl public-read

# Notify via webhook with the JSON response
response_json="{\"id\": \"$job_id\", \"url\": \"https://$s3_bucket.s3.amazonaws.com/$s3_output_path\"}"
echo $response_json
curl -X POST -H "Content-Type: application/json" -d "$response_json" $webhook_url
