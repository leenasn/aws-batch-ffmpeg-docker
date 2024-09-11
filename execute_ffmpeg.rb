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

# Main function to process the video
def execute_ffmpeg(video_id, params, output_file)
  s3_bucket = ENV["S3_BUCKET"]
  s3_output_path = ENV["S3_OUTPUT_DIR"].to_s
  puts "params #{params} video_id #{video_id} output_file #{output_file}"
  begin
    ffmpeg_command = "ffmpeg -y #{params} \"#{@output_dir}/#{output_file}\""
    # Run FFmpeg command
    puts "calling ffmpeg #{ffmpeg_command}"
    # stdout, stderr, status = Open3.capture3(ffmpeg_command)
    status = system(ffmpeg_command)
    unless status
      # puts "ffmpeg failed with error #{stderr}"
      notify_webhook(video_id, {}, "FFmpeg command \"#{ffmpeg_command}\" failed")
      return
    end

    # Upload the output video to S3      
    s3_file = "#{s3_output_path.empty? ? "" : "#{s3_output_path}/"}#{output_file}"
    s3 = Aws::S3::Resource.new(region: ENV["AWS_REGION"])
    obj = s3.bucket(s3_bucket).object(s3_file)
    File.open("#{@output_dir}/#{output_file}", "rb") do | file |
      obj.put(body: file, acl: "public-read", content_type: "video/mp4")
    end
    s3_output_url = obj.public_url
    puts "Uploaded to S3 #{s3_output_url}"
    # Notify via webhook with the success response
    output_json = {}
    output_json["output_file_url"] = s3_output_url
    notify_webhook(video_id, output_json)
  rescue => e
    puts "error #{e.message}"
    puts e.backtrace.join("\n")
    notify_webhook(video_id, {}, "Processing failed for #{params}: #{e.message}")
  end
end

# Entry point
@output_dir = "outputs-#{Time.now.to_i}"
begin  
  Dir.mkdir(@output_dir) unless Dir.exist?(@output_dir)
  execute_ffmpeg(ARGV[0], ARGV[1], ARGV[2])
rescue => e
  puts "Fatal error: #{e.message}"
ensure
  begin
    Dir.glob("#{@output_dir}/*").each do |file|
      File.delete(file)
    end
    FileUtils.rm_rf(@output_dir) if Dir.exist?(@output_dir)
  rescue => e
    puts "Error while deleting files #{e.message}"
  end
end
