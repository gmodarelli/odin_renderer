package renderer

import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

@(private="package")
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

@(private="package")
swap_chain_release_back_buffers :: proc() {
	if rctx.swap_chain != nil {
		for i in 0..<SWAP_CHAIN_BUFFER_COUNT {
			staging_descriptor_heap_free_descriptor(&rctx.rtv_descriptor_heap, rctx.back_buffer_rtvs[i])
			rctx.back_buffer_resources[i]->Release()
			rctx.back_buffer_resources[i] = nil
		}
	}
}