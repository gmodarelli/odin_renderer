package renderer

import "core:fmt"
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
	create_gpu()

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
check_hr :: proc(res: d3d12.HRESULT, message: string) {
	if (res >= windows.S_OK) {
		return
	}

	buf: [128]byte
	error_message := fmt.bprintf(buf[:], "%v. Error code: %0x\n", message, u32(res))
	logger.log(error_message)
	assert(false, error_message)
}
