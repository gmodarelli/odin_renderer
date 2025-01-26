package renderer

import "core:fmt"
import "core:os"
import "core:sync"
import windows "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

import d3d12ma "../d3d12ma"
import logger "../logger"

SWAP_CHAIN_BUFFER_COUNT :: 3
NUM_FRAMES_IN_FLIGHT :: 2
NUM_RTV_STAGING_DESCRIPTORS :: 256
NUM_DSV_STAGING_DESCRIPTORS :: 32
NUM_SRV_STAGING_DESCRIPTORS :: 2048
NUM_SAMPLER_DESCRIPTORS :: 6
NUM_RESERVED_SRV_DESCRIPTORS :: 8192
NUM_SRV_RENDER_PASS_USER_DESCRIPTORS :: 65536

@(private)
Renderer :: struct {
	factory: ^dxgi.IFactory7,
	adapter: ^dxgi.IAdapter4,
	adapter_desc: dxgi.ADAPTER_DESC3,
	device: ^d3d12.IDevice5,
	allocator: rawptr,

	// Graphics Command Queue
	graphics_queue: Queue,

	// SwapChain data
	swap_chain: ^dxgi.ISwapChain4,
	swap_chain_width: u32,
	swap_chain_height: u32,

	// Descriptor heaps
	rtv_descriptor_heap: Descriptor_Heap,
	dsv_descriptor_heap: Descriptor_Heap,
	srv_descriptor_heap: Descriptor_Heap,
	sampler_descriptor_heap: Descriptor_Heap,
	srv_descriptor_heaps: [NUM_FRAMES_IN_FLIGHT]Descriptor_Heap,
	free_reserved_descriptor_indices: [NUM_RESERVED_SRV_DESCRIPTORS]u32,
	free_reserved_descriptor_indices_cursor: u32,

	// TODO: Convert these to a custom Resource struct
	back_buffer_resources: [SWAP_CHAIN_BUFFER_COUNT]^d3d12.IResource,
	back_buffer_rtvs: [SWAP_CHAIN_BUFFER_COUNT]Descriptor,

	// NOTE: These are debug-only
	debug: ^d3d12.IDebug5,
	debug_device: ^d3d12.IDebugDevice1,
	info_queue: ^d3d12.IInfoQueue,
}

@(private)
Descriptor :: struct {
	cpu_handle: d3d12.CPU_DESCRIPTOR_HANDLE,
	gpu_handle: d3d12.GPU_DESCRIPTOR_HANDLE,
	heap_index: u32,
}

@(private)
Descriptor_Heap :: struct {
	type: d3d12.DESCRIPTOR_HEAP_TYPE,
	max_descriptors: u32,
	descriptor_size: u32,
	is_shader_visible: bool,
	heap: ^d3d12.IDescriptorHeap,
	heap_start: Descriptor,
	usage_mutex: sync.Mutex,
	variant: Descriptor_Heap_Variant,
}

@(private)
Descriptor_Heap_Staging :: struct {
	free_descriptors: []u32,
	num_free_descriptors: u32,
	current_descriptor_index: u32,
	num_active_handles: u32,
}

@(private)
Descriptor_Heap_Render_Pass :: struct {
	num_reserved_handles: u32,
	current_descriptor_index: u32,
}

@(private)
Descriptor_Heap_Variant :: union {
	Descriptor_Heap_Staging,
	Descriptor_Heap_Render_Pass,
}

rctx: Renderer

create :: proc(window_handle: rawptr, width: u32, height: u32) {
	// Create DXGI Factory
	{
		factory_flags: dxgi.CREATE_FACTORY
		when ODIN_DEBUG {
			factory_flags += { .DEBUG }
		}
		hr := dxgi.CreateDXGIFactory2(factory_flags, dxgi.IFactory7_UUID, cast(^rawptr)&rctx.factory)
		check_hr(hr, "Failed to create factory")
	}

	when ODIN_DEBUG {
		hr := d3d12.GetDebugInterface(d3d12.IDebug5_UUID, cast(^rawptr)&rctx.debug)
		check_hr(hr, "Failed to get debug interface")
		rctx.debug->EnableDebugLayer();
	}

	// Create Device
	{
		adapter_index, found := find_suitable_gpu(rctx.factory)
		assert(found, "Failed to find a suitable GPU")

		hr := rctx.factory->EnumAdapterByGpuPreference(adapter_index, .HIGH_PERFORMANCE, dxgi.IAdapter4_UUID, cast(^rawptr)&rctx.adapter)
		check_hr(hr, "Failed to get DXGI Adapters")
		rctx.adapter->GetDesc3(&rctx.adapter_desc)

		buf: [128]byte
		message := fmt.bprintf(buf[:], "Selected GPU: %s", rctx.adapter_desc.Description)
		logger.log(message)

		hr = d3d12.CreateDevice((^dxgi.IUnknown)(rctx.adapter), ._12_2, d3d12.IDevice5_UUID, cast(^rawptr)&rctx.device)
		check_hr(hr, "Failed to create device")
	}

	when ODIN_DEBUG {
		hr = rctx.device->QueryInterface(d3d12.IDebugDevice1_UUID, cast(^rawptr)&rctx.debug_device)
		check_hr(hr, "Failed to query Debug Device")

		hr = rctx.device->QueryInterface(d3d12.IInfoQueue1_UUID, cast(^rawptr)&rctx.info_queue)
		check_hr(hr, "Failed to query Info Queue")

		hr = rctx.info_queue->SetBreakOnSeverity(.ERROR, true)
		check_hr(hr, "Failed to set break on severity error")
	}

	// Initialize D3D12 Memory Allocator
	{
		allocator_desc := d3d12ma.ALLOCATOR_DESC {
			Flags = { .DEFAULT_POOLS_NOT_ZEROED },
			pDevice = rctx.device,
			pAdapter = rctx.adapter,
		}
		hr := d3d12ma.CreateAllocator(&allocator_desc, &rctx.allocator)
		check_hr(hr, "Failed to create allocator")
	}

	queue_create(&rctx.graphics_queue, .DIRECT, "Graphics Queue")

	staging_descriptor_heap_create(&rctx.rtv_descriptor_heap, .RTV,
									NUM_RTV_STAGING_DESCRIPTORS, false, "RTV Descriptor Heap")
	staging_descriptor_heap_create(&rctx.dsv_descriptor_heap, .DSV,
									NUM_DSV_STAGING_DESCRIPTORS, false, "DSV Descriptor Heap")
	staging_descriptor_heap_create(&rctx.srv_descriptor_heap, .CBV_SRV_UAV,
									NUM_SRV_STAGING_DESCRIPTORS, false, "SRV Descriptor Heap")
	
	render_pass_descriptor_heap_create(&rctx.sampler_descriptor_heap, .SAMPLER,
										0, NUM_SAMPLER_DESCRIPTORS, "Sampler Descriptor Heap")

	for i in 0..<NUM_FRAMES_IN_FLIGHT {
		render_pass_descriptor_heap_create(&rctx.srv_descriptor_heaps[i], .CBV_SRV_UAV,
											NUM_RESERVED_SRV_DESCRIPTORS, NUM_SRV_RENDER_PASS_USER_DESCRIPTORS,
											"SRV Render Pass Descriptor Heap")
	}

	for i in 0..<NUM_RESERVED_SRV_DESCRIPTORS {
		rctx.free_reserved_descriptor_indices[i] = cast(u32)i
	}
	rctx.free_reserved_descriptor_indices_cursor = NUM_RESERVED_SRV_DESCRIPTORS - 1

	swap_chain_create(cast(dxgi.HWND)window_handle, width, height)

	/*
	// Testing resource allocation
	{
		resource_desc := d3d12.RESOURCE_DESC {
			Dimension = .BUFFER,
			Width = 256,
			Height = 1,
			DepthOrArraySize = 1,
			MipLevels = 1,
			Format = .UNKNOWN,
			SampleDesc = { Count = 1, Quality = 0 },
			Layout = .ROW_MAJOR,
		}
		resource: ^d3d12.IResource1
		allocation_desc := d3d12ma.ALLOCATION_DESC {
			HeapType = .DEFAULT,
		}
		resource_allocation: rawptr
		hr := d3d12ma.CreateResource(rctx.allocator, &allocation_desc, &resource_desc, { .COPY_DEST }, nil, &resource_allocation,
									d3d12.IResource1_UUID, cast(^rawptr)&resource)
		check_hr(hr, "Failed to create resource")
		defer {
			if resource != nil {
				resource->Release()
				(cast(^windows.IUnknown)resource_allocation)->Release()
			}
		}
	}
	*/
}

destroy :: proc() {
	wait_for_idle()

	swap_chain_destroy()

	d3d12ma.DestroyAllocator(rctx.allocator)

	queue_destroy(&rctx.graphics_queue)

	descriptor_heap_destroy(&rctx.sampler_descriptor_heap)
	descriptor_heap_destroy(&rctx.srv_descriptor_heap)
	descriptor_heap_destroy(&rctx.dsv_descriptor_heap)
	descriptor_heap_destroy(&rctx.rtv_descriptor_heap)

	for i in 0..<NUM_FRAMES_IN_FLIGHT {
		descriptor_heap_destroy(&rctx.srv_descriptor_heaps[i])
	}

	rctx.device->Release()
	rctx.device = nil
	rctx.adapter->Release()
	rctx.adapter = nil
	rctx.factory->Release()
	rctx.factory = nil

	when ODIN_DEBUG {
		rctx.info_queue->Release()
		rctx.info_queue = nil
		rctx.debug->Release()
		rctx.debug = nil

		hr := rctx.debug_device->ReportLiveDeviceObjects({ .DETAIL, .SUMMARY, .IGNORE_INTERNAL })
		check_hr(hr, "Failed to Report Live Device Objects")

		refcount := rctx.debug_device->Release()
		rctx.debug_device = nil
		assert(refcount == 0, "D3D12 leak detected")
	}
}

handle_resize :: proc(width: u32, height: u32) {
	wait_for_idle()

	assert(rctx.swap_chain != nil, "Missing swap chain")

	swap_chain_release_back_buffers()
	rctx.swap_chain->ResizeBuffers(0, 0, 0, .UNKNOWN, {})
	swap_chain_create_back_buffers()
}

render :: proc() {
}

@(private)
wait_for_idle :: proc() {
	queue_wait_for_idle(&rctx.graphics_queue)
}

@(private)
descriptor_heap_create :: proc(descriptor_heap: ^Descriptor_Heap, type: d3d12.DESCRIPTOR_HEAP_TYPE, num_descriptors: u32, is_shader_visible: bool, debug_name: string) {
	descriptor_heap.type = type
	descriptor_heap.max_descriptors = num_descriptors
	descriptor_heap.is_shader_visible = is_shader_visible

	desc := d3d12.DESCRIPTOR_HEAP_DESC {
		Type = type,
		NumDescriptors = num_descriptors,
	}

	if is_shader_visible {
		desc.Flags = { .SHADER_VISIBLE }
	}

	hr := rctx.device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, cast(^rawptr)&descriptor_heap.heap)
	check_hr(hr, "Failed to create descriptor heap")

	when ODIN_DEBUG {
		descriptor_heap.heap->SetName(windows.utf8_to_wstring(debug_name))
	}

	descriptor_heap.heap->GetCPUDescriptorHandleForHeapStart(&descriptor_heap.heap_start.cpu_handle)
	if is_shader_visible {
		descriptor_heap.heap->GetGPUDescriptorHandleForHeapStart(&descriptor_heap.heap_start.gpu_handle)
	}

	descriptor_heap.descriptor_size = rctx.device->GetDescriptorHandleIncrementSize(type)
}

@(private)
staging_descriptor_heap_create :: proc(descriptor_heap: ^Descriptor_Heap, type: d3d12.DESCRIPTOR_HEAP_TYPE, num_descriptors: u32, is_shader_visible: bool, debug_name: string) {
	descriptor_heap_create(descriptor_heap, type, num_descriptors, is_shader_visible, debug_name)

	descriptor_heap.variant = Descriptor_Heap_Staging {
		free_descriptors = make([]u32, descriptor_heap.max_descriptors),
		num_free_descriptors = 0,
		current_descriptor_index = 0,
		num_active_handles = 0,
	}
}

@(private)
staging_descriptor_heap_get_new_descriptor :: proc(descriptor_heap: ^Descriptor_Heap) -> Descriptor {
	descriptor: Descriptor

	if sync.mutex_guard(&descriptor_heap.usage_mutex) {
		staging_heap := cast(^Descriptor_Heap_Staging)&descriptor_heap.variant

		heap_index: u32 = 0
		if staging_heap.current_descriptor_index < descriptor_heap.max_descriptors {
			heap_index = staging_heap.current_descriptor_index
			staging_heap.current_descriptor_index += 1
		} else if staging_heap.num_free_descriptors > 0 {
			staging_heap.num_free_descriptors -= 1
			heap_index = staging_heap.free_descriptors[staging_heap.num_free_descriptors]
		} else {
			assert(false, "Ran out of dynamic descriptor heap handles, need to increase heap size")
		}
			
		cpu_handle := descriptor_heap.heap_start.cpu_handle
		cpu_handle.ptr += cast(uint)(heap_index * descriptor_heap.descriptor_size)

		staging_heap.num_active_handles += 1

		descriptor.cpu_handle = cpu_handle
		descriptor.heap_index = heap_index
	}

	return descriptor
}

@(private)
staging_descriptor_heap_free_descriptor :: proc(descriptor_heap: ^Descriptor_Heap, descriptor: Descriptor) {
	if sync.mutex_guard(&descriptor_heap.usage_mutex) {
		staging_heap := cast(^Descriptor_Heap_Staging)&descriptor_heap.variant
		staging_heap.free_descriptors[staging_heap.num_free_descriptors] = descriptor.heap_index
		staging_heap.num_free_descriptors += 1

		assert(staging_heap.num_active_handles > 0, "Freeing heap handles when there should be none left")
		staging_heap.num_active_handles -= 1
	}
}

@(private)
descriptor_heap_destroy :: proc(descriptor_heap: ^Descriptor_Heap) {
	switch v in &descriptor_heap.variant {
		case Descriptor_Heap_Staging:
			descriptor_heap.heap->Release()
			delete(v.free_descriptors)
			assert(v.num_active_handles == 0, "There were active handles when the heap was destroyed")
			break
		case Descriptor_Heap_Render_Pass:
			descriptor_heap.heap->Release()
			break
	}
}

@(private)
render_pass_descriptor_heap_create :: proc(descriptor_heap: ^Descriptor_Heap, type: d3d12.DESCRIPTOR_HEAP_TYPE, num_reserved_descriptors: u32, num_user_descriptors: u32, debug_name: string) {
	descriptor_heap_create(descriptor_heap, type, num_reserved_descriptors + num_user_descriptors, true, debug_name)

	descriptor_heap.variant = Descriptor_Heap_Render_Pass {
		num_reserved_handles = num_reserved_descriptors,
		current_descriptor_index = num_reserved_descriptors,
	}
}

@(private)
render_pass_descriptor_heap_destroy :: proc(descriptor_heap: ^Descriptor_Heap) {
	descriptor_heap.heap->Release()
}

@(private)
render_pass_descriptor_heap_reset :: proc(descriptor_heap: ^Descriptor_Heap) {
	render_pass_heap := cast(^Descriptor_Heap_Render_Pass)&descriptor_heap.variant
	render_pass_heap.current_descriptor_index = render_pass_heap.num_reserved_handles
}

@(private)
render_pass_descriptor_heap_allocate_block :: proc(descriptor_heap: ^Descriptor_Heap, count: u32) -> Descriptor {
	heap_index: u32 = 0

	if sync.mutex_guard(&descriptor_heap.usage_mutex) {
		render_pass_heap := cast(^Descriptor_Heap_Render_Pass)&descriptor_heap.variant
		block_end := render_pass_heap.current_descriptor_index + count
		assert(block_end < descriptor_heap.max_descriptors, "Ran out of descriptor heap handles, need to increase heap size")
		heap_index = render_pass_heap.current_descriptor_index
		render_pass_heap.current_descriptor_index = block_end
	}

	cpu_handle := descriptor_heap.heap_start.cpu_handle
	cpu_handle.ptr += cast(uint)(heap_index * descriptor_heap.descriptor_size)
	gpu_handle := descriptor_heap.heap_start.gpu_handle
	gpu_handle.ptr += cast(u64)(heap_index * descriptor_heap.descriptor_size)

	return {
		cpu_handle = cpu_handle,
		gpu_handle = gpu_handle,
		heap_index = heap_index,
	}
}

@(private)
render_pass_descriptor_heap_get_reserved_descriptor :: proc(descriptor_heap: ^Descriptor_Heap, index: u32) -> Descriptor {
	render_pass_heap := cast(^Descriptor_Heap_Render_Pass)&descriptor_heap.variant
	assert(index < render_pass_heap.num_reserved_handles, "Ran out of reserved descriptor heap handles, need to increase heap size")

	cpu_handle := descriptor_heap.heap_start.cpu_handle
	cpu_handle.ptr += cast(uint)(index * descriptor_heap.descriptor_size)
	gpu_handle := descriptor_heap.heap_start.gpu_handle
	gpu_handle.ptr += cast(u64)(index * descriptor_heap.descriptor_size)

	return {
		cpu_handle = cpu_handle,
		gpu_handle = gpu_handle,
		heap_index = index,
	}
}

@(private)
swap_chain_create :: proc(window_handle: dxgi.HWND, width: u32, height: u32) {
	assert(rctx.factory != nil, "Factory not initialized")
	assert(rctx.device != nil, "Device not initialized")
	assert(rctx.graphics_queue.queue != nil, "Graphics command queue not initialized")
	assert(window_handle != nil, "No native window handle provided")

	rctx.swap_chain_width = width
	rctx.swap_chain_height = height

	desc := dxgi.SWAP_CHAIN_DESC1 {
		Width = width,
		Height = height,
		Format = .R8G8B8A8_UNORM,
		SampleDesc = { Count = 1 },
		BufferUsage = { .RENDER_TARGET_OUTPUT },
		BufferCount = SWAP_CHAIN_BUFFER_COUNT,
		Scaling = .STRETCH,
		SwapEffect = .FLIP_DISCARD,
		AlphaMode = .UNSPECIFIED,
	}

	swap_chain_1: ^dxgi.ISwapChain1
	hr := rctx.factory->CreateSwapChainForHwnd(cast(^dxgi.IUnknown)rctx.graphics_queue.queue, window_handle, 
														&desc, nil, nil, &swap_chain_1)
	check_hr(hr, "Failed to create swap chain for window")
	defer swap_chain_1->Release()

	hr = rctx.factory->MakeWindowAssociation(window_handle, { .NO_ALT_ENTER })
	check_hr(hr, "Failed to make window association")

	hr = swap_chain_1->QueryInterface(dxgi.ISwapChain4_UUID, cast(^rawptr)&rctx.swap_chain)
	check_hr(hr, "Failed query swap chain 4")

	swap_chain_create_back_buffers()

	color_space: dxgi.COLOR_SPACE_TYPE = .RGB_FULL_G22_NONE_P709
	color_space_support: dxgi.SWAP_CHAIN_COLOR_SPACE_SUPPORT
	hr = rctx.swap_chain->CheckColorSpaceSupport(color_space, &color_space_support)
	check_hr(hr, "Failed to check swap chain color space support")

	if color_space_support == { .PRESENT } {
		rctx.swap_chain->SetColorSpace1(color_space)
	}
}

@(private)
swap_chain_destroy :: proc() {
	swap_chain_release_back_buffers()
	if rctx.swap_chain != nil {
		rctx.swap_chain->Release()
		rctx.swap_chain = nil
	}
}

@(private)
swap_chain_create_back_buffers :: proc() {
	if rctx.swap_chain != nil {
		for i in 0..<SWAP_CHAIN_BUFFER_COUNT {
			back_buffer_resource: ^d3d12.IResource
			rtv_handle := staging_descriptor_heap_get_new_descriptor(&rctx.rtv_descriptor_heap)

			rtv_desc := d3d12.RENDER_TARGET_VIEW_DESC {
				Format = .R8G8B8A8_UNORM_SRGB,
				ViewDimension = .TEXTURE2D,
			}
			hr := rctx.swap_chain->GetBuffer(cast(u32)i, d3d12.IResource_UUID, cast(^rawptr)&rctx.back_buffer_resources[i])
			check_hr(hr, "Failed to get swap chain buffer")
			rctx.back_buffer_rtvs[i] = rtv_handle
		}
	}
}

@(private)
swap_chain_release_back_buffers :: proc() {
	if rctx.swap_chain != nil {
		for i in 0..<SWAP_CHAIN_BUFFER_COUNT {
			staging_descriptor_heap_free_descriptor(&rctx.rtv_descriptor_heap, rctx.back_buffer_rtvs[i])
			rctx.back_buffer_resources[i]->Release()
			rctx.back_buffer_resources[i] = nil
		}
	}
}

@(private)
check_hr :: proc(res: d3d12.HRESULT, message: string) {
	if (res >= windows.S_OK) {
		return
	}

	buf: [128]byte
	error_message := fmt.bprintf(buf[:], "%v. Error code: %0x\n", message, u32(res))
	logger.log(error_message)
	os.exit(-1)
}

@(private)
find_suitable_gpu :: proc(factory: ^dxgi.IFactory7) -> (u32, bool) {
	adapter: ^dxgi.IAdapter4
	max_dedicated_memory: u64 = 0
	best_adapter_index: u32 = 0
	suitable_gpu_found := false

	for i: u32 = 0; factory->EnumAdapterByGpuPreference(i, .HIGH_PERFORMANCE, dxgi.IAdapter4_UUID, cast(^rawptr)&adapter) == windows.S_OK; i += 1 {
		defer adapter->Release()
		desc: dxgi.ADAPTER_DESC3
		adapter->GetDesc3(&desc)

		if .SOFTWARE in desc.Flags {
			continue
		}

		hr := d3d12.CreateDevice((^dxgi.IUnknown)(adapter), ._12_2, d3d12.IDevice5_UUID, nil)
		if hr < windows.S_OK {
			continue
		}

		device: ^d3d12.IDevice5
		hr = d3d12.CreateDevice((^dxgi.IUnknown)(adapter), ._12_2, d3d12.IDevice5_UUID, cast(^rawptr)&device)
		check_hr(hr, "Failed to create device")
		defer device->Release()

		shader_model_support: d3d12.SHADER_MODEL = ._6_7
		hr = device->CheckFeatureSupport(.SHADER_MODEL, cast(rawptr)&shader_model_support, size_of(d3d12.SHADER_MODEL))
		if hr < windows.S_OK {
			continue
		}

		if desc.DedicatedVideoMemory > max_dedicated_memory {
			best_adapter_index = i
			max_dedicated_memory = desc.DedicatedVideoMemory
			suitable_gpu_found = true
		}
	}

	return best_adapter_index, suitable_gpu_found
}