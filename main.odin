package main

import "core:fmt"
import sdl "vendor:sdl2"

main :: proc() {
	if sdl.Init(sdl.INIT_VIDEO) < 0 {
		log("Failed to initialize SDL")
		return
	}
	defer sdl.Quit()

	sdl_window := sdl.CreateWindow("Odin D3D12", sdl.WINDOWPOS_UNDEFINED, sdl.WINDOWPOS_UNDEFINED, 1920, 1080, { .ALLOW_HIGHDPI, .SHOWN, .RESIZABLE })
	if sdl_window == nil {
		log("Failed to create SDL Window")
		return
	}
	defer sdl.DestroyWindow(sdl_window)

	window_info: sdl.SysWMinfo
	sdl.GetWindowWMInfo(sdl_window, &window_info)
	window_handle := window_info.info.win.window

	renderer_ctx: Renderer_Context
	initialize_renderer(&renderer_ctx, window_handle, 1920, 1080)
	defer destroy_renderer(&renderer_ctx)

	loop: for {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .KEYDOWN:
				#partial switch event.key.keysym.sym {
				case .ESCAPE:
					break loop
				}
			case .QUIT:
				break loop
			}
		}
	}
}