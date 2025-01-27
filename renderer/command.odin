package renderer

import windows "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

@(private="package")
Command :: struct {
	type: d3d12.COMMAND_LIST_TYPE,
	command_list: ^d3d12.IGraphicsCommandList4,
	current_descriptor_heaps: [d3d12.DESCRIPTOR_HEAP_TYPE]^d3d12.IDescriptorHeap,
	command_allocators: [NUM_FRAMES_IN_FLIGHT]^d3d12.ICommandAllocator,
	resource_barriers: [MAX_QUEUED_BARRIERS]d3d12.RESOURCE_BARRIER,
	num_queued_barriers: u32,
	current_srv_heap: ^Descriptor_Heap,
	current_srv_heap_handle: d3d12.CPU_DESCRIPTOR_HANDLE,
	// TODO: current_pipeline: ^Pipeline_State_Object
}

@(private="package")
Command_Submission :: struct {
	type: d3d12.COMMAND_LIST_TYPE,
	fence_value: u64,
}

@(private="package")
Command_Submission_Result :: struct {
	frame_index: u32,
	submission_index: u32,
}

command_create :: proc(command: ^Command, type: d3d12.COMMAND_LIST_TYPE, debug_name: string) {
	command.type = type

	for i in 0..<NUM_FRAMES_IN_FLIGHT {
		hr := rctx.device->CreateCommandAllocator(type, d3d12.ICommandAllocator_UUID, cast(^rawptr)&command.command_allocators[i])
		check_hr(hr, "Failed to create command allocator")
		when ODIN_DEBUG {
			command.command_allocators[i]->SetName(windows.utf8_to_wstring(debug_name))
		}
	}

	hr := rctx.device->CreateCommandList1({}, type, {}, d3d12.IGraphicsCommandList1_UUID, cast(^rawptr)&command.command_list)
	check_hr(hr, "Failed to create command list")
}

command_destroy :: proc(command: ^Command) {
	if command.command_list != nil {
		command.command_list->Release()
		command.command_list = nil
	}

	for i in 0..<NUM_FRAMES_IN_FLIGHT {
		command.command_allocators[i]->Release()
		command.command_allocators[i] = nil
	}
}

command_reset :: proc(command: ^Command) {
	frame_index := rctx.frame_index

	command.command_allocators[frame_index]->Reset()
	command.command_list->Reset(command.command_allocators[frame_index], nil)

	if command.type != .COPY {
		bind_descriptor_heaps(command)
	}
}

command_bind_render_targets :: proc(command: ^Command, resources: []^Resource, depth: ^Resource) {
	render_target_handles: [d3d12.SIMULTANEOUS_RENDER_TARGET_COUNT]d3d12.CPU_DESCRIPTOR_HANDLE
	depth_stencil_handle: d3d12.CPU_DESCRIPTOR_HANDLE

	for i in 0..<len(resources) {
		render_target := cast(^Resource_Texture)(&resources[i].variant)
		render_target_handles[i] = render_target.rtv_descriptor.cpu_handle
	}

	if depth != nil {
		render_target := cast(^Resource_Texture)(&depth.variant)
		depth_stencil_handle = render_target.dsv_descriptor.cpu_handle
	}

	command.command_list->OMSetRenderTargets(cast(u32)len(resources), &render_target_handles[0], false,
											depth != nil ? &depth_stencil_handle : nil)
}

command_set_default_viewport_and_scissor :: proc(command: ^Command, width: u32, height: u32) {
	viewport := d3d12.VIEWPORT {
		Width = cast(f32)width,
		Height = cast(f32)height,
		MinDepth = 0.0,
		MaxDepth = 1.0,
	}

	scissor := d3d12.RECT {
		bottom = cast(i32)height,
		right = cast(i32)width,
	}

	command.command_list->RSSetViewports(1, &viewport)
	command.command_list->RSSetScissorRects(1, &scissor)
}

command_clear_render_target :: proc(command: ^Command, resource: ^Resource, color: ^[4]f32) {
	texture := cast(^Resource_Texture)(&resource.variant)
	command.command_list->ClearRenderTargetView(texture.rtv_descriptor.cpu_handle, color, 0, nil)
}

command_add_barrier :: proc(command: ^Command, resource: ^Resource, new_state: d3d12.RESOURCE_STATES) {
	if command.num_queued_barriers > MAX_QUEUED_BARRIERS {
		command_flush_barriers(command)
	}

	old_state := resource.state

	if command.type == .COMPUTE {
		assert(is_valid_compute_resource_state(old_state), "old state is not a valid compute state")
		assert(is_valid_compute_resource_state(new_state), "new state is not a valid compute state")
	}

	if old_state != new_state {
		barrier_desc := &command.resource_barriers[command.num_queued_barriers]
		command.num_queued_barriers += 1

		barrier_desc^ = {
			Type = .TRANSITION,
			Transition = {
				pResource = resource.resource,
				Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
				StateBefore = old_state,
				StateAfter = new_state,
			},
		}

		resource.state = new_state
	} else if new_state == { .UNORDERED_ACCESS } {
		barrier_desc := &command.resource_barriers[command.num_queued_barriers]
		command.num_queued_barriers += 1

		barrier_desc^ = {
			Type = .UAV,
			UAV = {
				pResource = resource.resource,
			},
		}
	}
}

command_flush_barriers :: proc(command: ^Command) {
	if command.num_queued_barriers > 0 {
		command.command_list->ResourceBarrier(command.num_queued_barriers, &command.resource_barriers[0])
		command.num_queued_barriers = 0
	}
}

@(private="file")
bind_descriptor_heaps :: proc(command: ^Command) {
	command.current_srv_heap = &rctx.srv_descriptor_heaps[rctx.frame_index]
	render_pass_descriptor_heap_reset(command.current_srv_heap)

	heaps_to_bind := [?]^d3d12.IDescriptorHeap {
		command.current_srv_heap.heap,
		rctx.sampler_descriptor_heap.heap,
	}

	command.command_list->SetDescriptorHeaps(len(heaps_to_bind), (^^d3d12.IDescriptorHeap)(&heaps_to_bind[0]))
}

@(private="file")
is_valid_compute_resource_state :: proc(state: d3d12.RESOURCE_STATES) -> bool {
	return state == { .UNORDERED_ACCESS } ||
			state == { .NON_PIXEL_SHADER_RESOURCE } ||
			state == { .COPY_DEST } ||
			state == { .COPY_SOURCE }
}