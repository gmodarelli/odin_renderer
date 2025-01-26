package main

import "core:fmt"
import "core:os"
import "core:sync"
import windows "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

import "d3d12ma"

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
	graphics_queue: ^d3d12.ICommandQueue,

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

	// back_buffer_resources: [SWAP_CHAIN_BUFFER_COUNT]^d3d12.IResource,
	// back_buffer_rtvs: [SWAP_CHAIN_BUFFER_COUNT]

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
	num_active_handle: u32,
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

@(private)
renderer: Renderer

initialize_renderer :: proc(window_handle: rawptr, width: u32, height: u32) {
	// Create DXGI Factory
	{
		factory_flags: dxgi.CREATE_FACTORY
		when ODIN_DEBUG {
			factory_flags += { .DEBUG }
		}
		hr := dxgi.CreateDXGIFactory2(factory_flags, dxgi.IFactory7_UUID, cast(^rawptr)&renderer.factory)
		check_hr(hr, "Failed to create factory")
	}

	when ODIN_DEBUG {
		hr := d3d12.GetDebugInterface(d3d12.IDebug5_UUID, cast(^rawptr)&renderer.debug)
		check_hr(hr, "Failed to get debug interface")
		renderer.debug->EnableDebugLayer();
	}

	// Create Device
	{
		adapter_index, found := find_suitable_gpu(renderer.factory)
		assert(found, "Failed to find a suitable GPU")

		hr := renderer.factory->EnumAdapterByGpuPreference(adapter_index, .HIGH_PERFORMANCE, dxgi.IAdapter4_UUID, cast(^rawptr)&renderer.adapter)
		check_hr(hr, "Failed to get DXGI Adapters")
		renderer.adapter->GetDesc3(&renderer.adapter_desc)

		buf: [128]byte
		message := fmt.bprintf(buf[:], "Selected GPU: %s", renderer.adapter_desc.Description)
		log(message)

		hr = d3d12.CreateDevice((^dxgi.IUnknown)(renderer.adapter), ._12_2, d3d12.IDevice5_UUID, cast(^rawptr)&renderer.device)
		check_hr(hr, "Failed to create device")
	}

	when ODIN_DEBUG {
		hr = renderer.device->QueryInterface(d3d12.IDebugDevice1_UUID, cast(^rawptr)&renderer.debug_device)
		check_hr(hr, "Failed to query Debug Device")

		hr = renderer.device->QueryInterface(d3d12.IInfoQueue1_UUID, cast(^rawptr)&renderer.info_queue)
		check_hr(hr, "Failed to query Info Queue")

		hr = renderer.info_queue->SetBreakOnSeverity(.ERROR, true)
		check_hr(hr, "Failed to set break on severity error")
	}

	// Initialize D3D12 Memory Allocator
	{
		allocator_desc := d3d12ma.ALLOCATOR_DESC {
			Flags = { .DEFAULT_POOLS_NOT_ZEROED },
			pDevice = renderer.device,
			pAdapter = renderer.adapter,
		}
		hr := d3d12ma.CreateAllocator(&allocator_desc, &renderer.allocator)
		check_hr(hr, "Failed to create allocator")
	}

	create_command_queue(&renderer.graphics_queue, .DIRECT, "Graphics Queue")

	create_staging_descriptor_heap(&renderer.rtv_descriptor_heap, .RTV,
									NUM_RTV_STAGING_DESCRIPTORS, false, "RTV Descriptor Heap")
	create_staging_descriptor_heap(&renderer.dsv_descriptor_heap, .DSV,
									NUM_DSV_STAGING_DESCRIPTORS, false, "DSV Descriptor Heap")
	create_staging_descriptor_heap(&renderer.srv_descriptor_heap, .CBV_SRV_UAV,
									NUM_SRV_STAGING_DESCRIPTORS, false, "SRV Descriptor Heap")
	
	create_render_pass_descriptor_heap(&renderer.sampler_descriptor_heap, .SAMPLER,
										0, NUM_SAMPLER_DESCRIPTORS, "Sampler Descriptor Heap")

	for i in 0..<NUM_FRAMES_IN_FLIGHT {
		create_render_pass_descriptor_heap(&renderer.srv_descriptor_heaps[i], .CBV_SRV_UAV,
											NUM_RESERVED_SRV_DESCRIPTORS, NUM_SRV_RENDER_PASS_USER_DESCRIPTORS,
											"SRV Render Pass Descriptor Heap")
	}

	for i in 0..<NUM_RESERVED_SRV_DESCRIPTORS {
		renderer.free_reserved_descriptor_indices[i] = cast(u32)i
	}
	renderer.free_reserved_descriptor_indices_cursor = NUM_RESERVED_SRV_DESCRIPTORS - 1

	create_swap_chain(cast(dxgi.HWND)window_handle, width, height)

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
		hr := d3d12ma.CreateResource(renderer.allocator, &allocation_desc, &resource_desc, { .COPY_DEST }, nil, &resource_allocation,
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

destroy_renderer :: proc() {
	destroy_swap_chain()

	d3d12ma.DestroyAllocator(renderer.allocator)

	destroy_command_queue(renderer.graphics_queue)

	destroy_descriptor_heap(&renderer.sampler_descriptor_heap)
	destroy_descriptor_heap(&renderer.srv_descriptor_heap)
	destroy_descriptor_heap(&renderer.dsv_descriptor_heap)
	destroy_descriptor_heap(&renderer.rtv_descriptor_heap)

	for i in 0..<NUM_FRAMES_IN_FLIGHT {
		destroy_descriptor_heap(&renderer.srv_descriptor_heaps[i])
	}

	renderer.device->Release()
	renderer.device = nil
	renderer.adapter->Release()
	renderer.adapter = nil
	renderer.factory->Release()
	renderer.factory = nil

	when ODIN_DEBUG {
		renderer.info_queue->Release()
		renderer.info_queue = nil
		renderer.debug->Release()
		renderer.debug = nil

		hr := renderer.debug_device->ReportLiveDeviceObjects({ .DETAIL, .SUMMARY, .IGNORE_INTERNAL })
		check_hr(hr, "Failed to Report Live Device Objects")

		refcount := renderer.debug_device->Release()
		renderer.debug_device = nil
		assert(refcount == 0, "D3D12 leak detected")
	}
}

@(private)
create_command_queue :: proc(queue: ^^d3d12.ICommandQueue, type: d3d12.COMMAND_LIST_TYPE, debug_name: string) {
	desc := d3d12.COMMAND_QUEUE_DESC{
		Type = type,
	}

	hr := renderer.device->CreateCommandQueue(&desc, d3d12.ICommandQueue_UUID, cast(^rawptr)queue);
	check_hr(hr, "Failed to create command queue")

	when ODIN_DEBUG {
		queue^->SetName(windows.utf8_to_wstring(debug_name))
	}

	// TODO: Create fence
}

@(private)
destroy_command_queue :: proc(queue: ^d3d12.ICommandQueue) {
	if queue != nil {
		queue->Release()
	}
}

@(private)
create_descriptor_heap :: proc(descriptor_heap: ^Descriptor_Heap, type: d3d12.DESCRIPTOR_HEAP_TYPE, num_descriptors: u32, is_shader_visible: bool, debug_name: string) {
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

	hr := renderer.device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, cast(^rawptr)&descriptor_heap.heap)
	check_hr(hr, "Failed to create descriptor heap")

	when ODIN_DEBUG {
		descriptor_heap.heap->SetName(windows.utf8_to_wstring(debug_name))
	}

	descriptor_heap.heap->GetCPUDescriptorHandleForHeapStart(&descriptor_heap.heap_start.cpu_handle)
	if is_shader_visible {
		descriptor_heap.heap->GetGPUDescriptorHandleForHeapStart(&descriptor_heap.heap_start.gpu_handle)
	}

	descriptor_heap.descriptor_size = renderer.device->GetDescriptorHandleIncrementSize(type)
}

@(private)
create_staging_descriptor_heap :: proc(descriptor_heap: ^Descriptor_Heap, type: d3d12.DESCRIPTOR_HEAP_TYPE, num_descriptors: u32, is_shader_visible: bool, debug_name: string) {
	create_descriptor_heap(descriptor_heap, type, num_descriptors, is_shader_visible, debug_name)

	descriptor_heap.variant = Descriptor_Heap_Staging {
		free_descriptors = make([]u32, descriptor_heap.max_descriptors),
		num_free_descriptors = descriptor_heap.max_descriptors,
		current_descriptor_index = 0,
		num_active_handle = 0,
	}
}

@(private)
destroy_descriptor_heap :: proc(descriptor_heap: ^Descriptor_Heap) {
	switch v in &descriptor_heap.variant {
		case Descriptor_Heap_Staging:
			descriptor_heap.heap->Release()
			delete(v.free_descriptors)
			assert(v.num_active_handle == 0, "There were active handles when the heap was destroyed")
			break
		case Descriptor_Heap_Render_Pass:
			descriptor_heap.heap->Release()
			break
	}
}

@(private)
destroy_render_pass_descriptor_heap :: proc(descriptor_heap: ^Descriptor_Heap) {
	descriptor_heap.heap->Release()
}

@(private)
create_render_pass_descriptor_heap :: proc(descriptor_heap: ^Descriptor_Heap, type: d3d12.DESCRIPTOR_HEAP_TYPE, num_reserved_descriptors: u32, num_user_descriptors: u32, debug_name: string) {
	create_descriptor_heap(descriptor_heap, type, num_reserved_descriptors + num_user_descriptors, true, debug_name)

	descriptor_heap.variant = Descriptor_Heap_Render_Pass {
		num_reserved_handles = num_reserved_descriptors,
		current_descriptor_index = num_reserved_descriptors,
	}
}

@(private)
create_swap_chain :: proc(window_handle: dxgi.HWND, width: u32, height: u32) {
	assert(renderer.factory != nil, "Factory not initialized")
	assert(renderer.device != nil, "Device not initialized")
	assert(renderer.graphics_queue != nil, "Graphics command queue not initialized")
	assert(window_handle != nil, "No native window handle provided")

	renderer.swap_chain_width = width
	renderer.swap_chain_height = height

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
	hr := renderer.factory->CreateSwapChainForHwnd(cast(^dxgi.IUnknown)renderer.graphics_queue, window_handle, 
														&desc, nil, nil, &swap_chain_1)
	check_hr(hr, "Failed to create swap chain for window")
	defer swap_chain_1->Release()

	hr = renderer.factory->MakeWindowAssociation(window_handle, { .NO_ALT_ENTER })
	check_hr(hr, "Failed to make window association")

	hr = swap_chain_1->QueryInterface(dxgi.ISwapChain4_UUID, cast(^rawptr)&renderer.swap_chain)
	check_hr(hr, "Failed query swap chain 4")

	// TODO: Create render targets
}

@(private)
destroy_swap_chain :: proc() {
	if renderer.swap_chain != nil {
		renderer.swap_chain->Release()
		renderer.swap_chain = nil
	}
}

@(private)
check_hr :: proc(res: d3d12.HRESULT, message: string) {
	if (res >= windows.S_OK) {
		return
	}

	buf: [128]byte
	error_message := fmt.bprintf(buf[:], "%v. Error code: %0x\n", message, u32(res))
	log(error_message)
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