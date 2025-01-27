package renderer

import windows "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

import d3d12ma "../d3d12ma"

@(private="package")
buffer_create :: proc(resource: ^Resource, desc: Buffer_Creation_Desc) {
	resource.desc = {
		Dimension = .BUFFER,
		Width = cast(u64)align_up(cast(u64)desc.size, 256),
		Height = 1,
		DepthOrArraySize = 1,
		MipLevels = 1,
		Format = .UNKNOWN,
		SampleDesc = { Count = 1 },
		Layout = .ROW_MAJOR,
	}

	resource.variant = Resource_Buffer{
		stride = desc.stride,
	}
	buffer := cast(^Resource_Buffer)&resource.variant

	num_elements := cast(u32)(buffer.stride > 0 ? desc.size / buffer.stride : 1)
	is_host_visible := .host_writable in desc.access_flags
	has_cbv := .cbv in desc.view_flags
	has_srv := .srv in desc.view_flags
	has_uav := .uav in desc.view_flags

	resource.state = is_host_visible ? d3d12.RESOURCE_STATE_GENERIC_READ : { .COPY_DEST }

	allocation_desc := d3d12ma.ALLOCATION_DESC {
		HeapType = desc.access_flags == { .host_writable } ? .UPLOAD : .DEFAULT,
	}
	hr := d3d12ma.CreateResource(rctx.allocator, &allocation_desc, &resource.desc, resource.state, nil, &resource.allocation,
								d3d12.IResource1_UUID, cast(^rawptr)&resource.resource)
	check_hr(hr, "Failed to create resource")
	resource.virtual_address = resource.resource->GetGPUVirtualAddress()

	if has_cbv {
		cbv_desc := d3d12.CONSTANT_BUFFER_VIEW_DESC {
			BufferLocation = resource.virtual_address,
			SizeInBytes = cast(u32)resource.desc.Width,
		}
		buffer.cbv_descriptor = staging_descriptor_heap_get_new_descriptor(&rctx.srv_descriptor_heap)
		rctx.device->CreateConstantBufferView(&cbv_desc, buffer.cbv_descriptor.cpu_handle)
	}

	if has_srv {
		srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC {
			ViewDimension = .BUFFER,
			Shader4ComponentMapping = 5768, // compilation error: d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
			Format = desc.is_raw_access ? .R32_TYPELESS : .UNKNOWN,
			Buffer = {
				NumElements = cast(u32)(desc.is_raw_access ? (desc.size / 4) : num_elements),
				StructureByteStride = desc.is_raw_access ? 0 : buffer.stride,
				Flags = desc.is_raw_access ? { .RAW } : {},
			},
		}
		buffer.srv_descriptor = staging_descriptor_heap_get_new_descriptor(&rctx.srv_descriptor_heap)
		rctx.device->CreateShaderResourceView(resource.resource, &srv_desc, buffer.srv_descriptor.cpu_handle)

		assert(rctx.free_reserved_descriptor_indices_cursor > 0)
		resource.descriptor_heap_index = rctx.free_reserved_descriptor_indices[rctx.free_reserved_descriptor_indices_cursor]
		rctx.free_reserved_descriptor_indices_cursor -= 1

		copy_srv_handle_to_reserved_table(resource.descriptor_heap_index, buffer.srv_descriptor)
	}

	if has_uav {
		uav_desc := d3d12.UNORDERED_ACCESS_VIEW_DESC {
			ViewDimension = .BUFFER,
			Format = desc.is_raw_access ? .R32_TYPELESS : .UNKNOWN,
			Buffer = {
				NumElements = cast(u32)(desc.is_raw_access ? (desc.size / 4) : num_elements),
				StructureByteStride = desc.is_raw_access ? 0 : buffer.stride,
				Flags = desc.is_raw_access ? { .RAW } : {},
			},
		}

		buffer.uav_descriptor = staging_descriptor_heap_get_new_descriptor(&rctx.srv_descriptor_heap)
		rctx.device->CreateUnorderedAccessView(resource.resource, nil, &uav_desc, buffer.uav_descriptor.cpu_handle)
	}

	if is_host_visible {
		resource.resource->Map(0, nil, cast(^rawptr)(&buffer.mapped_resource))
	}
}

@(private="package")
buffer_destroy :: proc(resource: ^Resource) {
	// TODO: Push this buffer into the destruction queue
	buffer := cast(^Resource_Buffer)&resource.variant

	if buffer.cbv_descriptor.cpu_handle.ptr != 0 {
		staging_descriptor_heap_free_descriptor(&rctx.srv_descriptor_heap, buffer.cbv_descriptor)
	}

	if buffer.uav_descriptor.cpu_handle.ptr != 0 {
		staging_descriptor_heap_free_descriptor(&rctx.srv_descriptor_heap, buffer.uav_descriptor)
	}

	if buffer.srv_descriptor.cpu_handle.ptr != 0 {
		staging_descriptor_heap_free_descriptor(&rctx.srv_descriptor_heap, buffer.srv_descriptor)
		
		assert(rctx.free_reserved_descriptor_indices_cursor < NUM_RESERVED_SRV_DESCRIPTORS - 1)
		rctx.free_reserved_descriptor_indices_cursor += 1
		rctx.free_reserved_descriptor_indices[rctx.free_reserved_descriptor_indices_cursor] = resource.descriptor_heap_index
	}

	if buffer.mapped_resource != nil {
		resource.resource->Unmap(0, nil)
	}

	resource.resource->Release()
	(cast(^windows.IUnknown)resource.allocation)->Release()
}

@(private="file")
align_up :: proc(x: u64, align: u64) -> u64 {
	assert(0 == (align & (align - 1)), "must align to a power of two")
	return (x + (align - 1)) &~ (align - 1)
}

@(private="file")
copy_srv_handle_to_reserved_table :: proc(descriptor_heap_index: u32, srv_descriptor: Descriptor) {
	for i in 0..<NUM_FRAMES_IN_FLIGHT {
		target_descriptor := render_pass_descriptor_heap_get_reserved_descriptor(&rctx.srv_descriptor_heaps[i], descriptor_heap_index)
		rctx.device->CopyDescriptorsSimple(1, target_descriptor.cpu_handle, srv_descriptor.cpu_handle, .CBV_SRV_UAV)
	}
}

@(private="package")
Resource :: struct {
	desc: d3d12.RESOURCE_DESC,
	resource: ^d3d12.IResource,
	allocation: rawptr,
	virtual_address: d3d12.GPU_VIRTUAL_ADDRESS,
	state: d3d12.RESOURCE_STATES,
	descriptor_heap_index: u32,
	variant: Resource_Variant,
}

@(private="package")
Resource_Buffer :: struct {
	mapped_resource: ^u8,
	cbv_descriptor: Descriptor,
	srv_descriptor: Descriptor,
	uav_descriptor: Descriptor,
	stride: u32,
}

@(private="package")
Resource_Texture :: struct {
	rtv_descriptor: Descriptor,
	dsv_descriptor: Descriptor,
	srv_descriptor: Descriptor,
	uav_descriptor: Descriptor,
}

@(private="package")
Resource_Variant :: union {
	Resource_Buffer,
	Resource_Texture,
}

@(private="package")
Buffer_Creation_Desc :: struct {
	size: u32,
	stride: u32,
	view_flags: Buffer_View_Flags,
	access_flags: Buffer_Access_Flags,
	is_raw_access: bool,
}

@(private="package")
Buffer_Access_Flag :: enum {
	gpu_only,
	host_writable,
}

@(private="package")
Buffer_Access_Flags :: distinct bit_set[Buffer_Access_Flag]

@(private="package")
Buffer_View_Flag :: enum {
	cbv,
	srv,
	uav,
}

@(private="package")
Buffer_View_Flags :: distinct bit_set[Buffer_View_Flag]