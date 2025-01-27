package renderer

import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

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