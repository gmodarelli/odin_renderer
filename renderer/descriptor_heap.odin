package renderer

import "core:sync"
import windows "core:sys/windows"
import d3d12 "vendor:directx/d3d12"

@(private="package")
Descriptor :: struct {
	cpu_handle: d3d12.CPU_DESCRIPTOR_HANDLE,
	gpu_handle: d3d12.GPU_DESCRIPTOR_HANDLE,
	heap_index: u32,
}

@(private="package")
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

@(private="package")
Descriptor_Heap_Staging :: struct {
	free_descriptors: []u32,
	num_free_descriptors: u32,
	current_descriptor_index: u32,
	num_active_handles: u32,
}

@(private="package")
Descriptor_Heap_Render_Pass :: struct {
	num_reserved_handles: u32,
	current_descriptor_index: u32,
}

@(private="package")
Descriptor_Heap_Variant :: union {
	Descriptor_Heap_Staging,
	Descriptor_Heap_Render_Pass,
}

@(private="package")
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

@(private="package")
staging_descriptor_heap_create :: proc(descriptor_heap: ^Descriptor_Heap, type: d3d12.DESCRIPTOR_HEAP_TYPE, num_descriptors: u32, is_shader_visible: bool, debug_name: string) {
	descriptor_heap_create(descriptor_heap, type, num_descriptors, is_shader_visible, debug_name)

	descriptor_heap.variant = Descriptor_Heap_Staging {
		free_descriptors = make([]u32, descriptor_heap.max_descriptors),
		num_free_descriptors = 0,
		current_descriptor_index = 0,
		num_active_handles = 0,
	}
}

@(private="package")
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

@(private="package")
staging_descriptor_heap_free_descriptor :: proc(descriptor_heap: ^Descriptor_Heap, descriptor: Descriptor) {
	if sync.mutex_guard(&descriptor_heap.usage_mutex) {
		staging_heap := cast(^Descriptor_Heap_Staging)&descriptor_heap.variant
		staging_heap.free_descriptors[staging_heap.num_free_descriptors] = descriptor.heap_index
		staging_heap.num_free_descriptors += 1

		assert(staging_heap.num_active_handles > 0, "Freeing heap handles when there should be none left")
		staging_heap.num_active_handles -= 1
	}
}

@(private="package")
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

@(private="package")
render_pass_descriptor_heap_create :: proc(descriptor_heap: ^Descriptor_Heap, type: d3d12.DESCRIPTOR_HEAP_TYPE, num_reserved_descriptors: u32, num_user_descriptors: u32, debug_name: string) {
	descriptor_heap_create(descriptor_heap, type, num_reserved_descriptors + num_user_descriptors, true, debug_name)

	descriptor_heap.variant = Descriptor_Heap_Render_Pass {
		num_reserved_handles = num_reserved_descriptors,
		current_descriptor_index = num_reserved_descriptors,
	}
}

@(private="package")
render_pass_descriptor_heap_destroy :: proc(descriptor_heap: ^Descriptor_Heap) {
	descriptor_heap.heap->Release()
}

@(private="package")
render_pass_descriptor_heap_reset :: proc(descriptor_heap: ^Descriptor_Heap) {
	render_pass_heap := cast(^Descriptor_Heap_Render_Pass)&descriptor_heap.variant
	render_pass_heap.current_descriptor_index = render_pass_heap.num_reserved_handles
}

@(private="package")
render_pass_descriptor_heap_allocate_block :: proc(descriptor_heap: ^Descriptor_Heap, count: u32) -> Descriptor {
	heap_index: u32 = 0

	if sync.mutex_guard(&descriptor_heap.usage_mutex) {
		render_pass_heap := cast(^Descriptor_Heap_Render_Pass)&descriptor_heap.variant
		block_end := render_pass_heap.current_descriptor_index + count
		assert(block_end <= descriptor_heap.max_descriptors, "Ran out of descriptor heap handles, need to increase heap size")
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

@(private="package")
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