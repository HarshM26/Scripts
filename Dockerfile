FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

# Install required packages
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    pkg-config \
    libopencv-dev \
    libavcodec-dev \
    libavformat-dev \
    libswscale-dev \
    && rm -rf /var/lib/apt/lists/*

# Working directory
WORKDIR /app

# Copy source file
COPY code.cpp /app/

# Create CMakeLists.txt
RUN echo 'cmake_minimum_required(VERSION 3.10)\n\
project(CameraIngest)\n\
set(CMAKE_CXX_STANDARD 14)\n\
find_package(OpenCV REQUIRED)\n\
include_directories(${OpenCV_INCLUDE_DIRS})\n\
add_executable(code code.cpp)\n\
target_link_libraries(code ${OpenCV_LIBS} pthread)' > CMakeLists.txt

# Build the application
RUN mkdir build && cd build && \
    cmake .. && \
    make && \
    cp code /usr/local/bin/

# Create output directory
RUN mkdir -p /app/frames

# Environment variables
ENV RTSP_URL="rtsp://192.168.1.100:8554/mystream"
ENV OUTPUT_DIR="/app/frames"
ENV FRAME_INTERVAL="1"

# Healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD find /app/frames -name '*.jpg' -mmin -2 | grep -q . || exit 1

# Run the application
CMD ["/usr/local/bin/code"]
