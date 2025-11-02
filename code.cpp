#include <opencv2/opencv.hpp>
#include <iostream>
#include <fstream>
#include <string>
#include <ctime>
#include <sys/stat.h>
#include <chrono>
#include <iomanip>
#include <sstream>
#include <csignal>
#include <atomic>
#include <thread>

std::atomic<bool> running(true);

void signalHandler(int signum) {
    std::cout << "\nInterrupt signal (" << signum << ") received. Shutting down...\n";
    running = false;
}

std::string getCurrentTimestamp() {
    auto now = std::chrono::system_clock::now();
    auto time = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()) % 1000;

    std::stringstream ss;
    ss << std::put_time(std::localtime(&time), "%Y%m%d_%H%M%S");
    ss << "_" << std::setfill('0') << std::setw(3) << ms.count();
    return ss.str();
}

bool createDirectory(const std::string& path) {
    struct stat info;
    if (stat(path.c_str(), &info) != 0) {
        return mkdir(path.c_str(), 0755) == 0;
    }
    return true;
}

int main(int argc, char** argv) {
    std::string rtspUrl = "rtsp://10.65.21.153:8554/wireless";
    std::string outputDir = "/app/frames";
    int jpegQuality = 90;
    double targetFPS = 30.0;

    if (const char* env_url = std::getenv("RTSP_URL")) {
        rtspUrl = env_url;
    }
    if (const char* env_dir = std::getenv("OUTPUT_DIR")) {
        outputDir = env_dir;
    }
    if (const char* env_fps = std::getenv("TARGET_FPS")) {
        targetFPS = std::stod(env_fps);
    } else if (const char* env_interval = std::getenv("FRAME_INTERVAL")) {
        double interval = std::stod(env_interval);
        if (interval > 0) {
            targetFPS = 1.0 / interval;
        }
    }

    std::cout << "Camera Ingest Service Starting..." << std::endl;
    std::cout << "RTSP URL: " << rtspUrl << std::endl;
    std::cout << "Output Directory: " << outputDir << std::endl;
    std::cout << "Target FPS: " << targetFPS << std::endl;

    signal(SIGINT, signalHandler);
    signal(SIGTERM, signalHandler);

    if (!createDirectory(outputDir)) {
        std::cerr << "Failed to create output directory: " << outputDir << std::endl;
        return 1;
    }

    cv::VideoCapture cap;
    int reconnectAttempts = 0;
    const int maxReconnectAttempts = 10;

    while (running && reconnectAttempts < maxReconnectAttempts) {
        std::cout << "Attempting to connect to camera..." << std::endl;
        cap.open(rtspUrl, cv::CAP_FFMPEG);

        if (cap.isOpened()) {
            std::cout << "Successfully connected to camera!" << std::endl;
            break;
        }

        reconnectAttempts++;
        std::cerr << "Failed to open RTSP stream. Attempt " << reconnectAttempts
                  << "/" << maxReconnectAttempts << std::endl;
        std::this_thread::sleep_for(std::chrono::seconds(3));
    }

    if (!cap.isOpened()) {
        std::cerr << "Could not connect to camera." << std::endl;
        return 1;
    }

    cap.set(cv::CAP_PROP_BUFFERSIZE, 1);

    double cameraFPS = cap.get(cv::CAP_PROP_FPS);
    if (cameraFPS <= 0 || cameraFPS > 120) {
        cameraFPS = 30.0;
    }

    std::cout << "Camera FPS reported: " << cameraFPS << std::endl;

    cv::Mat frame;
    int savedFrames = 0;
    std::vector<int> compressionParams = {cv::IMWRITE_JPEG_QUALITY, jpegQuality};

    auto startTime = std::chrono::steady_clock::now();
    int framesThisSecond = 0;

    double frameIntervalMs = 1000.0 / targetFPS;
    auto nextFrameTime = std::chrono::steady_clock::now();

    std::cout << "Starting frame capture..." << std::endl;

    while (running) {
        bool ret = cap.read(frame);

        if (!ret || frame.empty()) {
            std::cerr << "Failed to read frame. Reconnecting..." << std::endl;
            cap.release();
            std::this_thread::sleep_for(std::chrono::seconds(1));
            cap.open(rtspUrl, cv::CAP_FFMPEG);
            if (!cap.isOpened()) {
                std::this_thread::sleep_for(std::chrono::seconds(2));
                continue;
            }
            cap.set(cv::CAP_PROP_BUFFERSIZE, 1);
            continue;
        }

        auto now = std::chrono::steady_clock::now();
        if (now >= nextFrameTime) {
            std::string timestamp = getCurrentTimestamp();
            std::string filename = outputDir + "/frame_" + timestamp + ".jpg";

            if (cv::imwrite(filename, frame, compressionParams)) {
                savedFrames++;
                framesThisSecond++;
            }

            nextFrameTime = now + std::chrono::milliseconds((int)frameIntervalMs);
        }

        double elapsed = std::chrono::duration_cast<std::chrono::seconds>(now - startTime).count();
        if (elapsed >= 1.0) {
            std::cout << "Captured " << framesThisSecond << " frames in the last second" << std::endl;
            framesThisSecond = 0;
            startTime = std::chrono::steady_clock::now();
        }
    }

    cap.release();
    std::cout << "Service stopped. Total saved frames: " << savedFrames << std::endl;
    return 0;
}
