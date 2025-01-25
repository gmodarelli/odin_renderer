package main

import "core:fmt"
import "core:os"
import windows "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

import "d3d12ma"

SWAP_CHAIN_BUFFER_COUNT :: 3

Renderer_Context :: struct {
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
	back_buffer_resources: [SWAP_CHAIN_BUFFER_COUNT]^d3d12.IResource,
	back_buffer_rtvs: [SWAP_CHAIN_BUFFER_COUNT]

	// NOTE: These are debug-only
	debug: ^d3d12.IDebug5,
	debug_device: ^d3d12.IDebugDevice1,
	info_queue: ^d3d12.IInfoQueue,
}

initialize_renderer :: proc(renderer_ctx: ^Renderer_Context, window_handle: rawptr, width: u32, height: u32) {
	// Create DXGI Factory
	{
		factory_flags: dxgi.CREATE_FACTORY
		when ODIN_DEBUG {
			factory_flags += { .DEBUG }
		}
		hr := dxgi.CreateDXGIFactory2(factory_flags, dxgi.IFactory7_UUID, cast(^rawptr)&renderer_ctx.factory)
		check_hr(hr, "Failed to create factory")
	}

	when ODIN_DEBUG {
		hr := d3d12.GetDebugInterface(d3d12.IDebug5_UUID, cast(^rawptr)&renderer_ctx.debug)
		check_hr(hr, "Failed to get debug interface")
		renderer_ctx.debug->EnableDebugLayer();
	}

	// Create Device
	{
		adapter_index, found := find_suitable_gpu(renderer_ctx.factory)
		assert(found, "Failed to find a suitable GPU")

		hr := renderer_ctx.factory->EnumAdapterByGpuPreference(adapter_index, .HIGH_PERFORMANCE, dxgi.IAdapter4_UUID, cast(^rawptr)&renderer_ctx.adapter)
		check_hr(hr, "Failed to get DXGI Adapters")
		renderer_ctx.adapter->GetDesc3(&renderer_ctx.adapter_desc)

		buf: [128]byte
		message := fmt.bprintf(buf[:], "Selected GPU: %s", renderer_ctx.adapter_desc.Description)
		log(message)

		hr = d3d12.CreateDevice((^dxgi.IUnknown)(renderer_ctx.adapter), ._12_2, d3d12.IDevice5_UUID, cast(^rawptr)&renderer_ctx.device)
		check_hr(hr, "Failed to create device")
	}

	when ODIN_DEBUG {
		hr = renderer_ctx.device->QueryInterface(d3d12.IDebugDevice1_UUID, cast(^rawptr)&renderer_ctx.debug_device)
		check_hr(hr, "Failed to query Debug Device")

		hr = renderer_ctx.device->QueryInterface(d3d12.IInfoQueue1_UUID, cast(^rawptr)&renderer_ctx.info_queue)
		check_hr(hr, "Failed to query Info Queue")

		hr = renderer_ctx.info_queue->SetBreakOnSeverity(.ERROR, true)
		check_hr(hr, "Failed to set break on severity error")
	}

	// Initialize D3D12 Memory Allocator
	{
		allocator_desc := d3d12ma.ALLOCATOR_DESC {
			Flags = { .DEFAULT_POOLS_NOT_ZEROED },
			pDevice = renderer_ctx.device,
			pAdapter = renderer_ctx.adapter,
		}
		hr := d3d12ma.CreateAllocator(&allocator_desc, &renderer_ctx.allocator)
		check_hr(hr, "Failed to create allocator")
	}

	create_command_queue(renderer_ctx, &renderer_ctx.graphics_queue, .DIRECT, "Graphics Queue")
	create_swap_chain(renderer_ctx, cast(dxgi.HWND)window_handle, width, height)

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
		hr := d3d12ma.CreateResource(renderer_ctx.allocator, &allocation_desc, &resource_desc, { .COPY_DEST }, nil, &resource_allocation,
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

destroy_renderer :: proc(renderer_ctx: ^Renderer_Context) {
	destroy_swap_chain(renderer_ctx)

	d3d12ma.DestroyAllocator(renderer_ctx.allocator)

	destroy_command_queue(renderer_ctx, renderer_ctx.graphics_queue)

	renderer_ctx.device->Release()
	renderer_ctx.device = nil
	renderer_ctx.adapter->Release()
	renderer_ctx.adapter = nil
	renderer_ctx.factory->Release()
	renderer_ctx.factory = nil

	when ODIN_DEBUG {
		renderer_ctx.info_queue->Release()
		renderer_ctx.info_queue = nil
		renderer_ctx.debug->Release()
		renderer_ctx.debug = nil

		hr := renderer_ctx.debug_device->ReportLiveDeviceObjects({ .DETAIL, .SUMMARY, .IGNORE_INTERNAL })
		check_hr(hr, "Failed to Report Live Device Objects")

		refcount := renderer_ctx.debug_device->Release()
		renderer_ctx.debug_device = nil
		assert(refcount == 0, "D3D12 leak detected")
	}
}

@(private)
create_command_queue :: proc(renderer_ctx: ^Renderer_Context, queue: ^^d3d12.ICommandQueue, type: d3d12.COMMAND_LIST_TYPE, debug_name: string) {
	desc := d3d12.COMMAND_QUEUE_DESC{
		Type = type,
	}

	hr := renderer_ctx.device->CreateCommandQueue(&desc, d3d12.ICommandQueue_UUID, cast(^rawptr)queue);
	check_hr(hr, "Failed to create command queue")

	when ODIN_DEBUG {
		queue^->SetName(windows.utf8_to_wstring(debug_name))
	}

	// TODO: Create fence
}

@(private)
destroy_command_queue :: proc(renderer_ctx: ^Renderer_Context, queue: ^d3d12.ICommandQueue) {
	if queue != nil {
		queue->Release()
	}
}

@(private)
create_swap_chain :: proc(renderer_ctx: ^Renderer_Context, window_handle: dxgi.HWND, width: u32, height: u32) {
	assert(renderer_ctx.factory != nil, "Factory not initialized")
	assert(renderer_ctx.device != nil, "Device not initialized")
	assert(renderer_ctx.graphics_queue != nil, "Graphics command queue not initialized")
	assert(window_handle != nil, "No native window handle provided")

	renderer_ctx.swap_chain_width = width
	renderer_ctx.swap_chain_height = height

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
	hr := renderer_ctx.factory->CreateSwapChainForHwnd(cast(^dxgi.IUnknown)renderer_ctx.graphics_queue, window_handle, 
														&desc, nil, nil, &swap_chain_1)
	check_hr(hr, "Failed to create swap chain for window")
	defer swap_chain_1->Release()

	hr = renderer_ctx.factory->MakeWindowAssociation(window_handle, { .NO_ALT_ENTER })
	check_hr(hr, "Failed to make window association")

	hr = swap_chain_1->QueryInterface(dxgi.ISwapChain4_UUID, cast(^rawptr)&renderer_ctx.swap_chain)
	check_hr(hr, "Failed query swap chain 4")

	// TODO: Create render targets
}

@(private)
destroy_swap_chain :: proc(renderer_ctx: ^Renderer_Context) {
	if renderer_ctx.swap_chain != nil {
		renderer_ctx.swap_chain->Release()
		renderer_ctx.swap_chain = nil
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