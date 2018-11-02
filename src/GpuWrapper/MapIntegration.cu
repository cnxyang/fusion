#include "DeviceFuncs.h"
#include "DeviceParallelScan.h"

struct Fusion
{
	MapStruct map;
	float invfx, invfy;
	float fx, fy, cx, cy;
	float minDepth, maxDepth;
	int width, height;
	Matrix3f Rview;
	Matrix3f RviewInv;
	float3 tview;

	uint* noVisibleBlocks;

	PtrStep<float4> nmap;
	PtrStep<float> depth;
	PtrStep<uchar3> rgb;

	__device__ inline float2 project(float3& pt3d)
	{
		float2 pt2d;
		pt2d.x = fx * pt3d.x / pt3d.z + cx;
		pt2d.y = fy * pt3d.y / pt3d.z + cy;
		return pt2d;
	}

	__device__ inline float3 unproject(int& x, int& y, float& z)
	{
		float3 pt3d;
		pt3d.z = z;
		pt3d.x = z * (x - cx) * invfx;
		pt3d.y = z * (y - cy) * invfy;
		return Rview * pt3d + tview;
	}

	__device__ inline bool CheckVertexVisibility(float3 pt3d)
	{
		pt3d = RviewInv * (pt3d - tview);
		if (pt3d.z < 1e-3f)
			return false;
		float2 pt2d = project(pt3d);

		return pt2d.x >= 0 && pt2d.y >= 0 &&
			   pt2d.x < width && pt2d.y < height &&
			   pt3d.z >= minDepth && pt3d.z <= maxDepth;
	}

	__device__ inline bool CheckBlockVisibility(const int3& pos)
	{
		float scale = mapState.blockWidth();
		float3 corner = pos * scale;
		if (CheckVertexVisibility(corner))
			return true;
		corner.z += scale;
		if (CheckVertexVisibility(corner))
			return true;
		corner.y += scale;
		if (CheckVertexVisibility(corner))
			return true;
		corner.x += scale;
		if (CheckVertexVisibility(corner))
			return true;
		corner.z -= scale;
		if (CheckVertexVisibility(corner))
			return true;
		corner.y -= scale;
		if (CheckVertexVisibility(corner))
			return true;
		corner.x -= scale;
		corner.y += scale;
		if (CheckVertexVisibility(corner))
			return true;
		corner.x += scale;
		corner.y -= scale;
		corner.z += scale;
		if (CheckVertexVisibility(corner))
			return true;
		return false;
	}

	__device__ inline void CreateBlocks()
	{
		int x = blockIdx.x * blockDim.x + threadIdx.x;
		int y = blockIdx.y * blockDim.y + threadIdx.y;
		if (x >= width && y >= height)
			return;

		float z = depth.ptr(y)[x];
		if (isnan(z) || z < minDepth || z > maxDepth)
			return;

		float thresh = mapState.truncateDistance() / 2;
		float z_near = min(maxDepth, z - thresh);
		float z_far = min(maxDepth, z + thresh);
		if (z_near >= z_far)
			return;

		float3 pt_near = unproject(x, y, z_near) * mapState.invVoxelSize();
		float3 pt_far = unproject(x, y, z_far) * mapState.invVoxelSize();
		float3 dir = pt_far - pt_near;

		float length = norm(dir);
		int nSteps = (int) ceil(2.0 * length);
		dir = dir / (float) (nSteps - 1);

		for (int i = 0; i < nSteps; ++i) {
			int3 blockPos = map.posVoxelToBlock(make_int3(pt_near));
			map.CreateBlock(blockPos);
			pt_near += dir;
		}
	}

	__device__ inline void CheckFullVisibility()
	{
		__shared__ bool bScan;
		if (threadIdx.x == 0)
			bScan = false;
		__syncthreads();
		uint val = 0;

		int x = blockDim.x * blockIdx.x + threadIdx.x;
		if (x < mapState.maxNumHashEntries)
		{
			HashEntry& e = map.hashEntries[x];
			if (e.next != EntryAvailable)
			{
				if (CheckBlockVisibility(e.pos))
				{
					bScan = true;
					val = 1;
				}
			}
		}

		__syncthreads();
		if (bScan)
		{
			int offset = ComputeOffset<1024>(val, noVisibleBlocks);
			if (offset != -1 &&	x < mapState.maxNumHashEntries)
			{
				map.visibleEntries[offset] = map.hashEntries[x];
			}
		}
	}

	__device__ inline void integrateColor()
	{

		if(blockIdx.x >= mapState.maxNumHashEntries ||
		   blockIdx.x >= *noVisibleBlocks)
			return;

		HashEntry& entry = map.visibleEntries[blockIdx.x];
		if (entry.next == EntryAvailable)
			return;

		int3 block_pos = map.posBlockToVoxel(entry.pos);

		#pragma unroll
		for(int i = 0; i < 8; ++i)
		{
			int3 localPos = make_int3(threadIdx.x, threadIdx.y, i);
			int locId = map.posLocalToIdx(localPos);
			float3 pos = map.posVoxelToWorld(block_pos + localPos);
			pos = RviewInv * (pos - tview);
			int2 uv = make_int2(project(pos));
			if (uv.x < 0 || uv.y < 0 || uv.x >= width || uv.y >= height)
				continue;

			float dp = depth.ptr(uv.y)[uv.x];
			if (isnan(dp) || dp > maxDepth || dp < minDepth)
				continue;

			float thresh = mapState.truncateDistance();
			float sdf = dp - pos.z;

			if (sdf >= -thresh)
			{
				sdf = fmin(1.0f, sdf / thresh);
				float4 nl = nmap.ptr(uv.y)[uv.x];
				if(isnan(nl.x))
					continue;

				float w = cos(make_float3(-nl) * normalised(make_float3(Rview.rowx.z, Rview.rowy.z, Rview.rowz.z)));
				float3 val = make_float3(rgb.ptr(uv.y)[uv.x]);
				Voxel & prev = map.voxelBlocks[entry.next + locId];
				if(prev.weight == 0)
				{
					prev = Voxel(sdf, 1, make_uchar3(val));
				}
				else
				{
					val = val / 255.f;
					float3 old = make_float3(prev.color) / 255.f;
					float3 res = (w * 0.2f * val + (1 - w * 0.2f) * old) * 255.f;
					prev.sdf = (prev.sdf * prev.weight + w * sdf) / (prev.weight + w);
					prev.weight = min(255, prev.weight + 1);
					prev.color = make_uchar3(res);
				}
			}
		}
	}

	__device__ inline void deIntegrateColor() {

		if(blockIdx.x >= mapState.maxNumHashEntries ||
		   blockIdx.x >= *noVisibleBlocks)
			return;

		HashEntry& entry = map.visibleEntries[blockIdx.x];
		if (entry.next == EntryAvailable)
			return;

		int3 block_pos = map.posBlockToVoxel(entry.pos);

		#pragma unroll
		for(int i = 0; i < 8; ++i)
		{
			int3 localPos = make_int3(threadIdx.x, threadIdx.y, i);
			int locId = map.posLocalToIdx(localPos);
			float3 pos = map.posVoxelToWorld(block_pos + localPos);
			pos = RviewInv * (pos - tview);
			int2 uv = make_int2(project(pos));
			if (uv.x < 0 || uv.y < 0 || uv.x >= width || uv.y >= height)
				continue;

			float dp = depth.ptr(uv.y)[uv.x];
			if (isnan(dp) || dp > maxDepth || dp < minDepth)
				continue;

			float thresh = mapState.truncateDistance();
			float sdf = dp - pos.z;

			if (sdf >= -thresh) {

				sdf = fmin(1.0f, sdf / thresh);
				float4 nl = nmap.ptr(uv.y)[uv.x];
				if(isnan(nl.x))
					continue;

				float w = nl * normalised(make_float4(pos));
				w = 1;
				float3 val = make_float3(rgb.ptr(uv.y)[uv.x]);
				Voxel & prev = map.voxelBlocks[entry.next + locId];
				if(prev.weight == 0) {
					return;
				} else {
					val = val / 255.f;
					float3 old = make_float3(prev.color) / 255.f;
					float3 res = ((1 - w * 0.2f) * old - w * 0.2f * val) * 255.f;
					prev.sdf = (prev.sdf * prev.weight - w * sdf) / (prev.weight - w);
					prev.weight = max(0, prev.weight - 1);
					prev.color = make_uchar3(res);
				}
			}
		}
	}
};

__global__ void CreateBlocksKernel(Fusion fuse) {
	fuse.CreateBlocks();
}

__global__ void FuseColorKernal(Fusion fuse) {
	fuse.integrateColor();
}

__global__ void DefuseColorKernal(Fusion fuse) {
	fuse.deIntegrateColor();
}

__global__ void CheckVisibleBlockKernel(Fusion fuse) {
	fuse.CheckFullVisibility();
}

void CheckBlockVisibility(MapStruct map,
					     DeviceArray<uint> & noVisibleBlocks,
						 Matrix3f Rview,
						 Matrix3f RviewInv,
						 float3 tview,
						 int cols,
						 int rows,
						 float fx,
						 float fy,
						 float cx,
						 float cy,
						 float depthMax,
						 float depthMin,
						 uint * host_data) {

	noVisibleBlocks.clear();

	Fusion fuse;
	fuse.map = map;
	fuse.Rview = Rview;
	fuse.RviewInv = RviewInv;
	fuse.tview = tview;
	fuse.fx = fx;
	fuse.fy = fy;
	fuse.cx = cx;
	fuse.cy = cy;
	fuse.invfx = 1.0 / fx;
	fuse.invfy = 1.0 / fy;
	fuse.height = rows;
	fuse.width = cols;
	fuse.noVisibleBlocks = noVisibleBlocks;
	fuse.maxDepth = depthMax;
	fuse.minDepth = depthMin;

	dim3 thread = dim3(1024);
	dim3 block = dim3(DivUp((int) hostMapState.maxNumHashEntries, thread.x));

	CheckVisibleBlockKernel<<<block, thread>>>(fuse);

	host_data[0] = 0;
	noVisibleBlocks.download((void*) host_data);
	if (host_data[0] == 0)
		return;
}

void FuseMapColor(const DeviceArray2D<float> & depth,
				  const DeviceArray2D<uchar3> & color,
				  const DeviceArray2D<float4> & nmap,
				  DeviceArray<uint> & noVisibleBlocks,
				  Matrix3f Rview,
				  Matrix3f RviewInv,
				  float3 tview,
				  MapStruct map,
				  float fx,
				  float fy,
				  float cx,
				  float cy,
				  float depthMax,
				  float depthMin,
				  uint * host_data) {

	int cols = depth.cols;
	int rows = depth.rows;
	noVisibleBlocks.clear();

	Fusion fuse;
	fuse.map = map;
	fuse.Rview = Rview;
	fuse.RviewInv = RviewInv;
	fuse.tview = tview;
	fuse.fx = fx;
	fuse.fy = fy;
	fuse.cx = cx;
	fuse.cy = cy;
	fuse.invfx = 1.0 / fx;
	fuse.invfy = 1.0 / fy;
	fuse.depth = depth;
	fuse.rgb = color;
	fuse.nmap = nmap;
	fuse.height = rows;
	fuse.width = cols;
	fuse.noVisibleBlocks = noVisibleBlocks;
	fuse.maxDepth = hostMapState.depthMax_raycast;
	fuse.minDepth = hostMapState.depthMin_raycast;

	dim3 thread(16, 8);
	dim3 block(DivUp(cols, thread.x), DivUp(rows, thread.y));

	CreateBlocksKernel<<<block, thread>>>(fuse);

	SafeCall(cudaDeviceSynchronize());
	SafeCall(cudaGetLastError());

	thread = dim3(1024);
	block = dim3(DivUp((int) hostMapState.maxNumHashEntries, thread.x));

	CheckVisibleBlockKernel<<<block, thread>>>(fuse);

	SafeCall(cudaDeviceSynchronize());
	SafeCall(cudaGetLastError());

	host_data[0] = 0;
	noVisibleBlocks.download((void*) host_data);
	if (host_data[0] == 0)
		return;

	thread = dim3(8, 8);
	block = dim3(host_data[0]);

	FuseColorKernal<<<block, thread>>>(fuse);

	SafeCall(cudaDeviceSynchronize());
	SafeCall(cudaGetLastError());
}

void DefuseMapColor(const DeviceArray2D<float> & depth,
				  	const DeviceArray2D<uchar3> & color,
				  	const DeviceArray2D<float4> & nmap,
				  	DeviceArray<uint> & noVisibleBlocks,
				  	Matrix3f Rview,
				  	Matrix3f RviewInv,
				  	float3 tview,
				  	MapStruct map,
				  	float fx,
				  	float fy,
				  	float cx,
				  	float cy,
				  	float depthMax,
				  	float depthMin,
				  	uint * host_data) {

	int cols = depth.cols;
	int rows = depth.rows;
	noVisibleBlocks.clear();

	Fusion fuse;
	fuse.map = map;
	fuse.Rview = Rview;
	fuse.RviewInv = RviewInv;
	fuse.tview = tview;
	fuse.fx = fx;
	fuse.fy = fy;
	fuse.cx = cx;
	fuse.cy = cy;
	fuse.invfx = 1.0 / fx;
	fuse.invfy = 1.0 / fy;
	fuse.depth = depth;
	fuse.rgb = color;
	fuse.nmap = nmap;
	fuse.height = rows;
	fuse.width = cols;
	fuse.noVisibleBlocks = noVisibleBlocks;
	fuse.maxDepth = hostMapState.depthMax_raycast;
	fuse.minDepth = hostMapState.depthMin_raycast;

	dim3 thread = dim3(1024);
	dim3 block = dim3(DivUp((int) hostMapState.maxNumHashEntries, thread.x));

	CheckVisibleBlockKernel<<<block, thread>>>(fuse);

	SafeCall(cudaDeviceSynchronize());
	SafeCall(cudaGetLastError());

	host_data[0] = 0;
	noVisibleBlocks.download((void*) host_data);
	if (host_data[0] == 0)
		return;

	thread = dim3(8, 8);
	block = dim3(host_data[0]);

	DefuseColorKernal<<<block, thread>>>(fuse);

	SafeCall(cudaDeviceSynchronize());
	SafeCall(cudaGetLastError());
}

__global__ void ResetHashKernel(MapStruct map) {

	int x = blockIdx.x * blockDim.x + threadIdx.x;
	if(x < mapState.maxNumHashEntries) {
		map.hashEntries[x].release();
		map.visibleEntries[x].release();
	}

	if (x < mapState.maxNumBuckets) {
		map.bucketMutex[x] = EntryAvailable;
	}
}

__global__ void ResetSdfBlockKernel(MapStruct map) {

	int x = blockIdx.x * blockDim.x + threadIdx.x;
	if(x < mapState.maxNumVoxelBlocks) {
		map.heapMem[x] = mapState.maxNumVoxelBlocks - x - 1;
	}

	int blockIdx = x * mapState.blockSize3;
	for(int i = 0; i < mapState.blockSize3; ++i, ++blockIdx) {
		map.voxelBlocks[blockIdx].release();
	}

	if(x == 0) {
		map.heapCounter[0] = mapState.maxNumVoxelBlocks - 1;
		map.entryPtr[0] = 1;
	}
}

void ResetMap(MapStruct map) {

	dim3 thread(1024);
	dim3 block(DivUp((int) hostMapState.maxNumHashEntries, thread.x));

	ResetHashKernel<<<block, thread>>>(map);

	SafeCall(cudaDeviceSynchronize());
	SafeCall(cudaGetLastError());

	block = dim3(DivUp((int) hostMapState.maxNumVoxelBlocks, thread.x));
	ResetSdfBlockKernel<<<block, thread>>>(map);

	SafeCall(cudaDeviceSynchronize());
	SafeCall(cudaGetLastError());
}

__global__ void ResetKeyPointsKernel(KeyMap map) {
	int x = blockIdx.x * blockDim.x + threadIdx.x;
	map.ResetKeys(x);
}

void ResetKeyPoints(KeyMap map) {

	dim3 thread(1024);
	dim3 block(DivUp((int) KeyMap::maxEntries, thread.x));

	ResetKeyPointsKernel<<<block, thread>>>(map);

	SafeCall(cudaDeviceSynchronize());
	SafeCall(cudaGetLastError());
}

struct KeyFusion {

	__device__ __forceinline__ void CollectKeys() {

		__shared__ bool scan;
		if(threadIdx.x == 0)
			scan = false;
		__syncthreads();

		uint val = 0;
		int x = blockDim.x * blockIdx.x + threadIdx.x;
		if(x < map.Keys.size) {
			SURF * key = &map.Keys[x];
			if(key->valid) {
				scan = true;
				val = 1;
			}
		}
		__syncthreads();

		if(scan) {
			int offset = ComputeOffset<1024>(val, nokeys);
			if(offset > 0 && x < map.Keys.size) {
				memcpy(&keys[offset], &map.Keys[x], sizeof(SURF));
			}
		}
	}

	__device__ __forceinline__ void InsertKeys() {

		int x = blockDim.x * blockIdx.x + threadIdx.x;
		if (x < size)
			map.InsertKey(&keys[x], index[x]);
	}

	KeyMap map;

	uint * nokeys;

	PtrSz<SURF> keys;

	size_t size;

	PtrSz<int> index;
};

__global__ void CollectKeyPointsKernel(KeyFusion fuse) {
	fuse.CollectKeys();
}

__global__ void InsertKeyPointsKernel(KeyFusion fuse) {
	fuse.InsertKeys();
}

void CollectKeyPoints(KeyMap map, DeviceArray<SURF> & keys, DeviceArray<uint> & noKeys) {

	KeyFusion fuse;
	fuse.map = map;
	fuse.keys = keys;
	fuse.nokeys = noKeys;

	dim3 thread(1024);
	dim3 block(DivUp(map.Keys.size, thread.x));

	CollectKeyPointsKernel<<<block, thread>>>(fuse);

	SafeCall(cudaDeviceSynchronize());
	SafeCall(cudaGetLastError());
}

void InsertKeyPoints(KeyMap map, DeviceArray<SURF> & keys,
		DeviceArray<int> & keyIndex, size_t size) {

	if(size == 0)
		return;

	KeyFusion fuse;

	fuse.map = map;
	fuse.keys = keys;
	fuse.size = size;
	fuse.index = keyIndex;

	dim3 thread(1024);
	dim3 block(DivUp(size, thread.x));

	InsertKeyPointsKernel<<<block, thread>>>(fuse);

	SafeCall(cudaDeviceSynchronize());
	SafeCall(cudaGetLastError());
}
