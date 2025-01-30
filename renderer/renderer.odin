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
MAX_QUEUED_BARRIERS :: 16
MAX_COMMAND_SUBMISSIONS_PER_FRAME :: 256
MAX_BUFFER_UPLOADS_PER_FRAME :: 64

@(private)
Renderer :: struct {
	factory: ^dxgi.IFactory7,
	device: ^d3d12.IDevice5,
	adapter: ^dxgi.IAdapter4,
	allocator: rawptr,

	// Graphics Command Queue
	graphics_queue: Queue,

	// SwapChain data
	swap_chain: ^dxgi.ISwapChain4,
	swap_chain_width: u32,
	swap_chain_height: u32,
	hdr_output: bool,

	// Descriptor heaps
	rtv_descriptor_heap: Descriptor_Heap,
	dsv_descriptor_heap: Descriptor_Heap,
	srv_descriptor_heap: Descriptor_Heap,
	sampler_descriptor_heap: Descriptor_Heap,
	srv_descriptor_heaps: [NUM_FRAMES_IN_FLIGHT]Descriptor_Heap,
	free_reserved_descriptor_indices: [NUM_RESERVED_SRV_DESCRIPTORS]u32,
	free_reserved_descriptor_indices_cursor: u32,

	back_buffers: [SWAP_CHAIN_BUFFER_COUNT]Resource,

	frame_index: u32,
	end_of_frame_fences: [NUM_FRAMES_IN_FLIGHT]End_Of_Frame_Fences,

	graphics_command: Command,
	upload_commands: [NUM_FRAMES_IN_FLIGHT]Command,
	command_submissions: [NUM_FRAMES_IN_FLIGHT][]Command_Submission,
	num_command_submissions: [NUM_FRAMES_IN_FLIGHT]u32,
}

@(private)
End_Of_Frame_Fences :: struct {
	graphics_queue_fence_value: u64,
}

rctx: Renderer

create :: proc(window_handle: rawptr, width: u32, height: u32, gpu_debug: bool) {
	use_debug_layers := false

	when ODIN_DEBUG {
		use_debug_layers = true
	}

	if use_debug_layers {
		debug_interface: ^d3d12.IDebug
		if windows.SUCCEEDED(d3d12.GetDebugInterface(d3d12.IDebug5_UUID, cast(^rawptr)&debug_interface)) {
			defer debug_interface->Release()

			debug_interface->EnableDebugLayer();

			if gpu_debug {
				debug_interface1: ^d3d12.IDebug1
				if windows.SUCCEEDED(debug_interface->QueryInterface(d3d12.IDebug1_UUID, cast(^rawptr)&debug_interface1)) {
					debug_interface1->SetEnableGPUBasedValidation(true)
				}
			}
		}
	}

	factory_flags: dxgi.CREATE_FACTORY

	when ODIN_DEBUG {
		info_queue: ^dxgi.IInfoQueue
		if windows.SUCCEEDED(dxgi.DXGIGetDebugInterface1(0, dxgi.IInfoQueue_UUID, cast(^rawptr)&info_queue)) {
			defer info_queue->Release()

			factory_flags += { .DEBUG }
			info_queue->SetBreakOnSeverity(dxgi.DEBUG_ALL, .ERROR, true)
			info_queue->SetBreakOnSeverity(dxgi.DEBUG_ALL, .CORRUPTION, true)

			hide := []dxgi.INFO_QUEUE_MESSAGE_ID {
				80, // IDXGISwapChain::GetContainingOutput: The swapchain's adapter does not control the output on which the swapchain's window resides.
			}
			filter := dxgi.INFO_QUEUE_FILTER {
				DenyList = {
					NumIDs = cast(u32)len(hide),
					pIDList = &hide[0],
				},
			}
			info_queue->AddStorageFilterEntries(dxgi.DEBUG_DXGI, filter)
		}
	}

	// Create DXGI Factory
	{
		hr := dxgi.CreateDXGIFactory2(factory_flags, dxgi.IFactory7_UUID, cast(^rawptr)&rctx.factory)
		check_hr(hr, "Failed to create factory")
	}

	// Create Device
	create_gpu()

	when ODIN_DEBUG {
		//debug_device: ^d3d12.IDebugDevice1
		//hr := rctx.device->QueryInterface(d3d12.IDebugDevice1_UUID, cast(^rawptr)&debug_device)
		//check_hr(hr, "Failed to query Debug Device")

		d3d12_info_queue: ^d3d12.IInfoQueue
		if windows.SUCCEEDED(rctx.device->QueryInterface(d3d12.IInfoQueue1_UUID, cast(^rawptr)&d3d12_info_queue)) {
			defer d3d12_info_queue->Release()
			
			// Suppress messages based on their severity
			severities := []d3d12.MESSAGE_SEVERITY {
				.INFO,
			}

			// Suppress individual messages based on their ID
			deny_ids := []d3d12.MESSAGE_ID {
				// This occurs when there are uninitialized descriptors in a descriptor table, even when a
				// shader does not access the missing descriptors.  I find this is common when switching
				// shader permutations and not wanting to change much code to reorder resources.
				.INVALID_DESCRIPTOR_HANDLE,

				// Triggered when a shader does not export all color components of a render target, such as
				// when only writing RGB to an R10G10B10A2 buffer, ignoring alpha.
				.CREATEGRAPHICSPIPELINESTATE_PS_OUTPUT_RT_OUTPUT_MISMATCH,

				// This occurs when a descriptor table is unbound even when a shader does not access the missing
				// descriptors.  This is common with a root signature shared between disparate shaders that
				// don't all need the same types of resources.
				.COMMAND_LIST_DESCRIPTOR_TABLE_NOT_SET,

				// RESOURCE_BARRIER_DUPLICATE_SUBRESOURCE_TRANSITIONS
				.RESOURCE_BARRIER_DUPLICATE_SUBRESOURCE_TRANSITIONS,

				// Suppress errors from calling ResolveQueryData with timestamps that weren't requested on a given frame.
				// .RESOLVE_QUERY_INVALID_QUERY_STATE,

				// Ignoring InitialState D3D12_RESOURCE_STATE_COPY_DEST. Buffers are effectively created in state D3D12_RESOURCE_STATE_COMMON.
				// .CREATERESOURCE_STATE_IGNORED,
			}

			info_queue_filter := d3d12.INFO_QUEUE_FILTER {
				DenyList = {
					NumSeverities = cast(u32)len(severities),
					pSeverityList = &severities[0],
					NumIDs = cast(u32)len(deny_ids),
					pIDList = &deny_ids[0],
				},
			}
			d3d12_info_queue->PushStorageFilter(&info_queue_filter)
			d3d12_info_queue->SetBreakOnSeverity(.ERROR, true)
		}
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

	create_samplers()

	for i in 0..<NUM_RESERVED_SRV_DESCRIPTORS {
		rctx.free_reserved_descriptor_indices[i] = cast(u32)i
	}
	rctx.free_reserved_descriptor_indices_cursor = NUM_RESERVED_SRV_DESCRIPTORS - 1

	for i in 0..<NUM_FRAMES_IN_FLIGHT {
		rctx.command_submissions[i] = make([]Command_Submission, MAX_COMMAND_SUBMISSIONS_PER_FRAME)
		rctx.num_command_submissions[i] = 0
	}

	command_create(&rctx.graphics_command, .DIRECT, "Graphics Command")

	for i in 0..<NUM_FRAMES_IN_FLIGHT {
		upload_command_create(&rctx.upload_commands[i])
	}

	swap_chain_create(cast(dxgi.HWND)window_handle, width, height)
	if rctx.hdr_output {
		logger.log("HDR Output")
	} else {
		logger.log("SDR Output")
	}
}

destroy :: proc() {
	wait_for_idle()

	for i in 0..<NUM_FRAMES_IN_FLIGHT {
		upload_command_destroy(&rctx.upload_commands[i])
	}

	for i in 0..<NUM_FRAMES_IN_FLIGHT {
		delete(rctx.command_submissions[i])
		rctx.num_command_submissions[i] = 0
	}

	command_destroy(&rctx.graphics_command)

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

	rctx.adapter->Release()
	rctx.adapter = nil
	rctx.factory->Release()
	rctx.factory = nil

	when ODIN_DEBUG {	
		debug_device: ^d3d12.IDebugDevice
		if windows.SUCCEEDED(rctx.device->QueryInterface(d3d12.IDebugDevice_UUID, cast(^rawptr)&debug_device)) {
			debug_device->ReportLiveDeviceObjects({ .DETAIL, .SUMMARY, .IGNORE_INTERNAL })
			debug_device->Release()
		}
	}

	rctx.device->Release()
	rctx.device = nil
}

handle_resize :: proc(width: u32, height: u32) {
	wait_for_idle()

	assert(rctx.swap_chain != nil, "Missing swap chain")

	swap_chain_release_back_buffers()
	rctx.swap_chain->ResizeBuffers(0, 0, 0, .UNKNOWN, {})
	swap_chain_create_back_buffers()
}

render :: proc() {
	begin_frame()
	frame_index := rctx.frame_index
	swap_chain_back_buffer_index := rctx.swap_chain->GetCurrentBackBufferIndex()
	back_buffer := &rctx.back_buffers[swap_chain_back_buffer_index]

	command_reset(&rctx.graphics_command)
	command_add_barrier(&rctx.graphics_command, back_buffer, { .RENDER_TARGET })
	command_flush_barriers(&rctx.graphics_command)

	command_bind_render_targets(&rctx.graphics_command, { back_buffer }, nil)
	command_set_default_viewport_and_scissor(&rctx.graphics_command, rctx.swap_chain_width, rctx.swap_chain_height)

	clear_color := [4]f32{ 0.2, 0.2, 0.2, 1.0 }
	command_clear_render_target(&rctx.graphics_command, back_buffer, &clear_color)

	command_add_barrier(&rctx.graphics_command, back_buffer, d3d12.RESOURCE_STATE_PRESENT)
	command_flush_barriers(&rctx.graphics_command)

	submit_work(&rctx.graphics_command)
	end_frame()
	present()
}

@(private)
create_samplers :: proc() {
	sampler_descs: [NUM_SAMPLER_DESCRIPTORS]d3d12.SAMPLER_DESC

	sampler_descs[0] = {
		Filter = .ANISOTROPIC,
		AddressU = .CLAMP,
		AddressV = .CLAMP,
		AddressW = .CLAMP,
		MaxAnisotropy = 16,
		MaxLOD = d3d12.FLOAT32_MAX,
	}

	sampler_descs[1] = {
		Filter = .ANISOTROPIC,
		AddressU = .WRAP,
		AddressV = .WRAP,
		AddressW = .WRAP,
		MaxAnisotropy = 16,
		MaxLOD = d3d12.FLOAT32_MAX,
	}

	sampler_descs[2] = {
		Filter = .COMPARISON_MIN_MAG_MIP_LINEAR,
		AddressU = .CLAMP,
		AddressV = .CLAMP,
		AddressW = .CLAMP,
		MaxLOD = d3d12.FLOAT32_MAX,
	}

	sampler_descs[3] = {
		Filter = .COMPARISON_MIN_MAG_MIP_LINEAR,
		AddressU = .WRAP,
		AddressV = .WRAP,
		AddressW = .WRAP,
		MaxLOD = d3d12.FLOAT32_MAX,
	}

	sampler_descs[4] = {
		Filter = .COMPARISON_MIN_MAG_MIP_POINT,
		AddressU = .CLAMP,
		AddressV = .CLAMP,
		AddressW = .CLAMP,
		MaxLOD = d3d12.FLOAT32_MAX,
	}

	sampler_descs[5] = {
		Filter = .COMPARISON_MIN_MAG_MIP_POINT,
		AddressU = .WRAP,
		AddressV = .WRAP,
		AddressW = .WRAP,
		MaxLOD = d3d12.FLOAT32_MAX,
	}

	sampler_descriptor_block := render_pass_descriptor_heap_allocate_block(&rctx.sampler_descriptor_heap, NUM_SAMPLER_DESCRIPTORS)
	current_descriptor_handle := sampler_descriptor_block.cpu_handle

	for i in 0..<NUM_SAMPLER_DESCRIPTORS {
		rctx.device->CreateSampler(&sampler_descs[i], current_descriptor_handle)
		current_descriptor_handle.ptr += cast(uint)rctx.sampler_descriptor_heap.descriptor_size
	}
}

@(private)
begin_frame :: proc() {
	rctx.frame_index = (rctx.frame_index + 1) % NUM_FRAMES_IN_FLIGHT
	d3d12ma.SetCurrentFrameIndex(rctx.allocator, cast(uint)rctx.frame_index)

	// Wait on fences from 2 frames ago
	queue_wait_for_fence_cpu_blocking(&rctx.graphics_queue, rctx.end_of_frame_fences[rctx.frame_index].graphics_queue_fence_value)

	rctx.num_command_submissions[rctx.frame_index] = 0
}

@(private)
end_frame :: proc() {
}

@(private)
present :: proc() {
	// TODO: Figure out the best way to present here, and make it work with VSync
	flags: dxgi.PRESENT
	params: dxgi.PRESENT_PARAMETERS
	rctx.swap_chain->Present1(0, flags, &params)
	rctx.end_of_frame_fences[rctx.frame_index].graphics_queue_fence_value = queue_signal_fence(&rctx.graphics_queue)
}

@(private)
submit_work :: proc(command: ^Command) -> Command_Submission_Result {
	if rctx.num_command_submissions[rctx.frame_index] >= MAX_COMMAND_SUBMISSIONS_PER_FRAME {
		assert(false, "Too many command submissions per frame")
	}

	fence_result: u64
	#partial switch command.type {
	case .DIRECT:
		fence_result = queue_execute_command_list(&rctx.graphics_queue, cast(^d3d12.ICommandList)command.command_list)
		break;
	}

	submission_result := Command_Submission_Result {
		frame_index = rctx.frame_index,
		submission_index = rctx.num_command_submissions[rctx.frame_index],
	}

	command_submission := Command_Submission {
		type = command.type,
		fence_value = fence_result,
	}

	rctx.command_submissions[rctx.frame_index][rctx.num_command_submissions[rctx.frame_index]] = command_submission
	rctx.num_command_submissions[rctx.frame_index] += 1

	return submission_result
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
