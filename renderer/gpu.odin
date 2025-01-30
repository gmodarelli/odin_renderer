package renderer

import "core:fmt"
import windows "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

import logger "../logger"

@(private="package")
create_gpu :: proc() {
	adapter_index, found := find_suitable_gpu()
	assert(found, "Failed to find a suitable GPU")

	hr := rctx.factory->EnumAdapterByGpuPreference(adapter_index, .HIGH_PERFORMANCE, dxgi.IAdapter4_UUID, cast(^rawptr)&rctx.adapter)
	check_hr(hr, "Failed to get DXGI Adapters")
	adapter_desc: dxgi.ADAPTER_DESC3
	rctx.adapter->GetDesc3(&adapter_desc)

	buf: [128]byte
	message := fmt.bprintf(buf[:], "Selected GPU: %s", adapter_desc.Description)
	logger.log(message)

	hr = d3d12.CreateDevice((^dxgi.IUnknown)(rctx.adapter), ._12_2, d3d12.IDevice5_UUID, cast(^rawptr)&rctx.device)
	check_hr(hr, "Failed to create device")

	when ODIN_DEBUG {
		// TODO: check for developer mode on Windows registry
		developer_mode_enabled := false

	}
}

@(private="file")
find_suitable_gpu :: proc() -> (u32, bool) {
	adapter: ^dxgi.IAdapter4
	max_dedicated_memory: u64 = 0
	best_adapter_index: u32 = 0
	suitable_gpu_found := false

	for i: u32 = 0; rctx.factory->EnumAdapterByGpuPreference(i, .HIGH_PERFORMANCE, dxgi.IAdapter4_UUID, cast(^rawptr)&adapter) == windows.S_OK; i += 1 {
		defer adapter->Release()
		desc: dxgi.ADAPTER_DESC3
		adapter->GetDesc3(&desc)

		if .SOFTWARE in desc.Flags {
			continue
		}

		device: ^d3d12.IDevice5
		if windows.FAILED(d3d12.CreateDevice((^dxgi.IUnknown)(adapter), ._12_2, d3d12.IDevice5_UUID, cast(^rawptr)&device)) {
			continue
		}
		defer device->Release()

		shader_model_support: d3d12.SHADER_MODEL = ._6_7
		if windows.FAILED(device->CheckFeatureSupport(.SHADER_MODEL, cast(rawptr)&shader_model_support, size_of(d3d12.SHADER_MODEL))) {
			continue
		}

		if desc.DedicatedVideoMemory < max_dedicated_memory {
			continue
		}

		best_adapter_index = i
		max_dedicated_memory = desc.DedicatedVideoMemory
		suitable_gpu_found = true
	}

	return best_adapter_index, suitable_gpu_found
}