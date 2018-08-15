#ifndef SYSTEM_HPP__
#define SYSTEM_HPP__

#include "Mapping.hpp"
#include "Viewer.hpp"
#include "Tracking.hpp"
#include <thread>

class Viewer;
class Tracking;

struct SysDesc {
	int cols, rows;
	float fx;
	float fy;
	float cx;
	float cy;
	float DepthCutoff;
	float DepthScale;
};

class System {
public:
	System(const char* str);
	System(SysDesc* pParam);
	void GrabImageRGBD(cv::Mat& imRGB, cv::Mat& imD);
	void SetParameters(SysDesc& desc);
	void RenderScene(cv::Mat& img);

private:
	Mapping* mpMap;
	Viewer* mpViewer;
	SysDesc* mpParam;
	Tracking* mpTracker;

	std::thread* mptViewer;
};

#endif
