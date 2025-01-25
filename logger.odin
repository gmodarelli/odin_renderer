package main

import "core:fmt"
import windows "core:sys/windows"

log :: proc(message: string) {
	fmt.println(message)
	windows.OutputDebugStringW(windows.utf8_to_wstring(message))
	windows.OutputDebugStringA("\n")
}