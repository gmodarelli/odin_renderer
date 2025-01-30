package renderer

import windows "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

SWAP_CHAIN_FORMAT :: dxgi.FORMAT.R10G10B10A2_UNORM
ALLOW_HDR :: true

@(private="package")
swap_chain_create :: proc(window_handle: dxgi.HWND, width: u32, height: u32) {
	assert(rctx.device != nil, "Device not initialized")
	assert(rctx.graphics_queue.queue != nil, "Graphics command queue not initialized")
	assert(window_handle != nil, "No native window handle provided")

	rctx.swap_chain_width = width
	rctx.swap_chain_height = height

	desc := dxgi.SWAP_CHAIN_DESC1 {
		Width = width,
		Height = height,
		Format = SWAP_CHAIN_FORMAT,
		SampleDesc = { Count = 1 },
		BufferUsage = { .RENDER_TARGET_OUTPUT },
		BufferCount = SWAP_CHAIN_BUFFER_COUNT,
		Scaling = .NONE,
		SwapEffect = .FLIP_DISCARD,
		AlphaMode = .IGNORE,
		Flags = { .ALLOW_MODE_SWITCH },
	}

	fullscreen_desc := dxgi.SWAP_CHAIN_FULLSCREEN_DESC {
		Windowed = true,
	}

	swap_chain_1: ^dxgi.ISwapChain1
	hr := rctx.factory->CreateSwapChainForHwnd(cast(^dxgi.IUnknown)rctx.graphics_queue.queue, window_handle, 
														&desc, &fullscreen_desc, nil, &swap_chain_1)
	check_hr(hr, "Failed to create swap chain for window")
	defer swap_chain_1->Release()

	hr = swap_chain_1->QueryInterface(dxgi.ISwapChain4_UUID, cast(^rawptr)&rctx.swap_chain)
	check_hr(hr, "Failed query swap chain 4")

	// Try to enable HDR Output
	enable_hrd_output()

	// hr = rctx.factory->MakeWindowAssociation(window_handle, { .NO_ALT_ENTER })
	// check_hr(hr, "Failed to make window association")

	swap_chain_create_back_buffers()
}

@(private="package")
swap_chain_destroy :: proc() {
	swap_chain_release_back_buffers()
	if rctx.swap_chain != nil {
		rctx.swap_chain->Release()
		rctx.swap_chain = nil
	}
}

@(private="package")
swap_chain_create_back_buffers :: proc() {
	if rctx.swap_chain != nil {
		for i in 0..<SWAP_CHAIN_BUFFER_COUNT {
			back_buffer_texture := cast(^Resource_Texture)(&rctx.back_buffers[i].variant)
			back_buffer_texture.rtv_descriptor = staging_descriptor_heap_get_new_descriptor(&rctx.rtv_descriptor_heap)

			rtv_desc := d3d12.RENDER_TARGET_VIEW_DESC {
				Format = SWAP_CHAIN_FORMAT,
				ViewDimension = .TEXTURE2D,
			}
			hr := rctx.swap_chain->GetBuffer(cast(u32)i, d3d12.IResource_UUID, cast(^rawptr)&rctx.back_buffers[i].resource)
			check_hr(hr, "Failed to get swap chain buffer")
			rctx.device->CreateRenderTargetView(rctx.back_buffers[i].resource, &rtv_desc, back_buffer_texture.rtv_descriptor.cpu_handle)

			rctx.back_buffers[i].state = d3d12.RESOURCE_STATE_PRESENT
		}
	}
}

@(private="package")
swap_chain_release_back_buffers :: proc() {
	if rctx.swap_chain != nil {
		for i in 0..<SWAP_CHAIN_BUFFER_COUNT {
			back_buffer_texture := cast(^Resource_Texture)(&rctx.back_buffers[i].variant)
			staging_descriptor_heap_free_descriptor(&rctx.rtv_descriptor_heap, back_buffer_texture.rtv_descriptor)
			rctx.back_buffers[i].resource->Release()
			rctx.back_buffers[i].resource = nil
		}
	}
}

@(private="file")
enable_hrd_output :: proc() {
	assert(rctx.swap_chain != nil, "Swap chain is not initialized")
	rctx.hdr_output = false

	dxgi_output: ^dxgi.IOutput
	dxgi_output6: ^dxgi.IOutput6
	desc: dxgi.OUTPUT_DESC1
	hdr_color_space_support: dxgi.SWAP_CHAIN_COLOR_SPACE_SUPPORT
	hdr_color_space: dxgi.COLOR_SPACE_TYPE = .RGB_FULL_G2084_NONE_P2020

	defer {
		if dxgi_output6 != nil { dxgi_output6->Release() }
		if dxgi_output != nil { dxgi_output->Release() }
	}

	if windows.FAILED(rctx.swap_chain->GetContainingOutput(&dxgi_output)) { return }
	if windows.FAILED(dxgi_output->QueryInterface(dxgi.IOutput6_UUID, cast(^rawptr)&dxgi_output6)) { return }
	if windows.FAILED(dxgi_output6->GetDesc1(&desc)) { return }

	if desc.ColorSpace != hdr_color_space { return }
	if windows.FAILED(rctx.swap_chain->CheckColorSpaceSupport(hdr_color_space, &hdr_color_space_support)) { return }
	
	if hdr_color_space_support == { .PRESENT } {
		if windows.SUCCEEDED(rctx.swap_chain->SetColorSpace1(hdr_color_space)) { 
			rctx.hdr_output = true
		}
	}
}