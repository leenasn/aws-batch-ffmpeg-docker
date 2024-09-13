require "aws-sdk-s3"
require "json"
require "net/http"
require "open-uri"
require "open3"
require "fileutils"

# Function to send a notification to the webhook
def notify_webhook(job_id, post_params, error = "")
  webhook_url = ENV["WEBHOOK_URL"]
  uri = URI.parse(webhook_url)
  header = { "Content-Type": "application/json" }

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true if uri.scheme == "https"

  request = Net::HTTP::Post.new(uri.request_uri, header)
  post_params["id"] = job_id
  post_params["error"] = error
  post_params["aws_batch_job_id"] = ENV["AWS_BATCH_JOB_ID"]
  request.body = post_params.to_json

  response = http.request(request)
  puts "Webhook response: #{response.code} for params #{post_params}"
rescue => e
  puts "Failed to notify webhook #{webhook_url} with error: #{e.message}"
end

def download_file_from_s3(video_id, url)
  s3 = Aws::S3::Client.new(region: ENV["AWS_REGION"])
  local_path = "#{@output_dir}/#{File.basename(url)}"
  uri = URI.parse(url)
  bucket = uri.host.split('.').first
  # Extract the object key
  key = URI.decode_www_form_component(uri.path[1..-1])
  # Get the object size to plan multipart download
  obj = s3.head_object(bucket: bucket, key: key)
  obj_size = obj.content_length

  # Define chunk size (e.g., 10 MB)
  chunk_size = 100 * 1024 * 1024
  num_chunks = (obj_size.to_f / chunk_size).ceil
  puts "Download started at #{Time.now} with #{num_chunks} chunks"
  File.open(local_path, 'wb') do |file|
    num_chunks.times do |i|
      range_start = i * chunk_size
      range_end = [(i + 1) * chunk_size - 1, obj_size - 1].min

      s3.get_object(bucket: bucket, key: key, range: "bytes=#{range_start}-#{range_end}") do |chunk|
        file.write(chunk)
      end
      puts "Downloaded chunk #{i + 1}/#{num_chunks} (#{((i + 1) * chunk_size / 1024.0 / 1024.0).round(2)} MB)"
    end
  end

  puts "Download completed successfully @ #{Time.now}!"
  return local_path
rescue Aws::S3::Errors::ServiceError => e
  puts "Failed to download file: #{e.message}"
  notify_webhook(video_id, {}, "Download failed for #{url}: #{e.message}")
  return ""
end

# Main function to process the video
def convert_to_hd(video_id, video_url, output_file)
  s3_bucket = ENV["S3_BUCKET"]
  s3_output_path = ENV["S3_OUTPUT_DIR"].to_s
  local_path = download_file_from_s3(video_id, video_url)
  # local_path = video_url
  if local_path.empty?
    notify_webhook(video_id, {}, "Invalid input file for ffmpeg #{local_path}")
    return
  end
  begin
    width, height, portrait, aspect_ratio, duration_in_minutes = get_video_info(video_id, local_path)
    initial_duration_in_minutes = duration_in_minutes
    puts "Video info: width: #{width}, height: #{height}, portrait: #{portrait}, aspect_ratio: #{aspect_ratio}"
    if (width > 1920 && height > 1080) || portrait
      # ffmpeg_command = "ffmpeg -y -i '#{video_url}' -vf 'scale=#{portrait ? "720:1280" : "1080:1920"},format=yuv420p' -c:v libx264 -preset veryfast -crf 28 -c:a aac -b:a 128k -movflags +faststart -threads 0 \"#{@output_dir}/#{output_file}\""
      ffmpeg_command = "ffmpeg -y -i '#{local_path}' -vf 'scale=#{portrait ? "720:1280" : "1080:1920"},format=yuv420p' -c:v libx264 -c:a aac -b:a 128k -movflags +faststart -threads 0 \"#{@output_dir}/#{output_file}\""
      # Run FFmpeg command
      puts "calling ffmpeg #{ffmpeg_command}"
      status = system(ffmpeg_command)
      unless status
        # puts "ffmpeg failed with error #{stderr}"
        notify_webhook(video_id, {}, "FFmpeg command \"#{ffmpeg_command}\" failed")
        return
      end
      width, height, portrait, aspect_ratio, duration_in_minutes = get_video_info(video_id, "#{@output_dir}/#{output_file}")
      if initial_duration_in_minutes == duration_in_minutes
        # Upload the output video to S3
        s3_file = "#{s3_output_path.empty? ? "" : "#{s3_output_path}/"}#{output_file}"
        s3 = Aws::S3::Resource.new(region: ENV["AWS_REGION"])
        obj = s3.bucket(s3_bucket).object(s3_file)
        File.open("#{@output_dir}/#{output_file}", "rb") do | file |
          obj.put(body: file, acl: "public-read", content_type: "video/mp4")
        end
        s3_output_url = obj.public_url
        puts "Uploaded to S3 #{s3_output_url}"
      else
        notify_webhook(video_id, {}, "Duration mismatch after conversion: #{initial_duration_in_minutes} vs #{duration_in_minutes}")
        return
      end
    else
      s3_output_url = video_url
    end
    # Notify via webhook with the success response
    output_json = {
      width: width,
      height: height,
      aspect_ratio: aspect_ratio,
      output_file_url: s3_output_url,
      portrait: portrait,
      duration_in_minutes: duration_in_minutes
    }
    notify_webhook(video_id, output_json)
  rescue => e
    puts "error #{e.message}"
    puts e.backtrace.join("\n")
    notify_webhook(video_id, {}, "Processing failed for #{video_url}: #{e.message}")
  end
end

def get_video_info(video_id, video_url)
  ffprobe_command = "ffprobe -v error -select_streams v:0 -show_entries stream=width,height:stream_side_data=rotation -of csv=p=0 #{video_url}"
  puts "calling ffprobe #{ffprobe_command}"
  output = `#{ffprobe_command}`
  portrait = false
  width = 1080
  height = 720
  aspect_ratio = "16:9"
  duration_in_minutes = nil
  if $?.success?
    puts "ffprobe output: #{output}"
    width, height, rotation = output.strip.split(',').select { | elem | !elem.empty?} .collect(&:to_i)
    puts "Video resolution: #{width}x#{height}, rotation: #{rotation}"
    if width > 0 && height > 0
      divisor = gcd(width, height)
      aspect_width = width / divisor
      aspect_height = height / divisor
      aspect_ratio = "#{aspect_width}:#{aspect_height}"
      portrait = true if aspect_ratio.to_s.eql?("9:16") || rotation.to_i < 0
    end
    ffprobe_command = "ffprobe -v error -select_streams v:0 -show_entries format=duration -of csv=p=0 #{video_url}"
    puts "calling ffprobe #{ffprobe_command}"
    output = `#{ffprobe_command}`
    if $?.success?
      duration_in_minutes = output.strip.to_f / 60
      puts "Video duration is #{duration_in_minutes} minutes"
    end
  else
    puts "ffprobe failed with with output #{output}, so setting portrait to true to convert to 720p"
    notify_webhook(video_id, {}, "FFprobe command \"#{ffprobe_command}\" failed")
    portrait = true
  end
  puts "width: #{width}, height: #{height}, portrait: #{portrait}, aspect_ratio: #{aspect_ratio}"
  [width, height, portrait, aspect_ratio, duration_in_minutes]
end

def gcd(a, b)
  while b != 0
    a, b = b, a % b
  end
  a
end

# Entry point
@output_dir = "outputs-#{Time.now.to_i}"
begin  
  Dir.mkdir(@output_dir) unless Dir.exist?(@output_dir)
  if ARGV[2].nil?
    video_id = ARGV[0]
    width, height, portrait, aspect_ratio, duration_in_minutes = get_video_info(video_id, ARGV[1])
    output_json = {
      width: width,
      height: height,
      aspect_ratio: aspect_ratio,
      portrait: portrait,
      duration_in_minutes: duration_in_minutes
    }
    notify_webhook(video_id, output_json)
  else
    convert_to_hd(ARGV[0], ARGV[1], ARGV[2])
  end
rescue => e
  puts "Fatal error: #{e.message}"
ensure
  begin
    FileUtils.rm_rf(@output_dir) if Dir.exist?(@output_dir)
  rescue => e
    puts "Error while deleting files #{e.message}"
  end
end
