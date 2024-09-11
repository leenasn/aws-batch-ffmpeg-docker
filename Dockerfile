# Use an official Ruby runtime as a parent image
FROM ruby:3.1

# Install FFmpeg
RUN apt-get update && apt-get install -y \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Install Bundler and necessary gems
RUN gem install bundler

# Copy Gemfile and Gemfile.lock if available
COPY Gemfile Gemfile.lock /app/

# Set the working directory
WORKDIR /app

# Install gems
RUN bundle install

# Copy the Ruby script
COPY process_video.rb /app/process_video.rb
COPY execute_ffmpeg.rb /app/execute_ffmpeg.rb
COPY convert_to_hd.rb /app/convert_to_hd.rb

# Make the script executable
RUN chmod +x /app/*.rb

# Command to run the script
CMD ["ruby", "/app/process_video.rb"]
