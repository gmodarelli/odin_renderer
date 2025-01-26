package main

import "core:fmt"
import "core:mem"
import sdl "vendor:sdl2"

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				for _, entry in track.allocation_map {
					buf: [128]byte
					message := fmt.bprintf(buf[:], "%v leaked %v bytes\n", entry.location, entry.size)
					log(message)
				}
			}

			if len(track.bad_free_array) > 0 {
				for entry in track.bad_free_array {
					buf: [128]byte
					message := fmt.bprintf(buf[:], "%v bad free at %v\n", entry.location, entry.memory)
					log(message)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

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
	is_window_minimized := false

	window_info: sdl.SysWMinfo
	sdl.GetWindowWMInfo(sdl_window, &window_info)
	window_handle := window_info.info.win.window

	renderer_create(window_handle, 1920, 1080)
	defer renderer_destroy()

	loop: for {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .KEYDOWN:
				#partial switch event.key.keysym.sym {
				case .ESCAPE:
					break loop
				}
			case .WINDOWEVENT:
				#partial switch event.window.event {
				case .RESIZED:
					new_width := cast(u32)event.window.data1
					new_height := cast(u32)event.window.data2

					buf: [128]byte
					message := fmt.bprintf(buf[:], "Window resized: %vx%v", new_width, new_height)
					log(message)

					if new_width > 0 && new_height > 0 {
						renderer_handle_resize(new_width, new_height)
					}
					break
				case .MINIMIZED:
					log("Window minimized")
					is_window_minimized = true
					break
				case .RESTORED:
					log("Window restored")
					is_window_minimized = false
					break
				}
				break
			case .QUIT:
				break loop
			}
		}

		if !is_window_minimized {
			renderer_draw()
		}
	}
}