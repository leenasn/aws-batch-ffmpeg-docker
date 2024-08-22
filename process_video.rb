require "aws-sdk-s3"
require "json"
require "net/http"
require "open-uri"
require "open3"

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
  request.body = post_params.to_json

  response = http.request(request)
  puts "Webhook response: #{response.code} for params #{post_params}"
rescue => e
  puts "Failed to notify webhook #{webhook_url} with error: #{e.message}"
end

# Main function to process the video
def process_video(s3_metadata_file_key)
  s3_client = Aws::S3::Client.new(region: ENV["AWS_REGION"])
  s3_bucket = ENV["S3_BUCKET"]
  # Download JSON file from S3
  begin
    puts "downloading s3_metadata_file #{s3_metadata_file_key}"
    json_file = s3_client.get_object(bucket: s3_bucket, key: s3_metadata_file_key).body.read
    params = JSON.parse(json_file)
  rescue => e
    puts "Failed to download or parse JSON file: #{e.message}"
    puts e.backtrace.join("\n")
    # notify_webhook("", {}, "Failed to download or parse JSON file: #{e.message}")    
    return
  end
  puts "Processing with JSON params #{params}"  
  input_video = params["video_url"]
  s3_output_path = params["s3_output_dir"].to_s
  # input_file_name = "input#{File.extname(input_video)}"
  # Download the input video from S3
  # s3_client.get_object(response_target: "input.mp4", bucket: s3_bucket, key: input_video)
  # unless File.exist?(input_file_name)
  #   begin
  #     IO.copy_stream(URI.open(input_video), input_file_name)
  #   rescue => e
  #     notify_webhook("", {}, "Failed to download video file: #{e.message}")
  #     puts e.backtrace.join("\n")
  #     return
  #   end
  # end
  params["clip_metadata"].each do | metadata |
    puts "metadata #{metadata}"
    video_id = metadata["video_id"]
    start_time = metadata["start_time"].to_s.gsub(",", ".").gsub('"', "")
    duration = metadata["duration"]
    output_file = metadata["output_file_name"]
    srt_file = metadata["srt_file"].to_s # Optional

    begin
      # Download the SRT file if provided
      unless srt_file.empty?
        s3_client.get_object(response_target: "subtitles.srt", bucket: s3_bucket, key: srt_file)
        ffmpeg_command = "ffmpeg -y -ss #{start_time} -t #{duration} -i \"#{input_video}\" -vf \"subtitles=subtitles.srt\" -c:a copy \"#{@output_dir}/#{output_file}\""
      else
        ffmpeg_command = "ffmpeg -y -ss #{start_time} -t #{duration} -i \"#{input_video}\" -c:a copy \"#{@output_dir}/#{output_file}\""
      end

      # Run FFmpeg command
      puts "calling ffmpeg #{ffmpeg_command}"
      status = system(ffmpeg_command)
      unless status
        puts "ffmpeg failed with error"
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
      output_json[metadata["attribute_name"]] = s3_output_url
      notify_webhook(video_id, output_json)
    rescue => e
      puts "error #{e.message}"
      puts e.backtrace.join("\n")
      notify_webhook(video_id, {}, "Processing failed for #{metadata["url_attribute"]}: #{e.message}")
    end
  end
end

# Entry point
@output_dir = "clips-#{Time.now.to_i}"
begin
  Dir.mkdir(@output_dir) unless Dir.exist?(@output_dir)
  process_video(ARGV[0])
rescue => e
  puts "Fatal error: #{e.message}"
ensure
  begin
    Dir.glob("#{@output_dir}/*").each do |file|
      # File.delete(file)
    end
  rescue => e
    puts "Error while deleting files #{e.message}"
  end
end
