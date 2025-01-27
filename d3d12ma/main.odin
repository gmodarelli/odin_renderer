package d3d12ma

import "core:c"
import "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

foreign import d3d12ma_c {
	"build/d3d12ma.lib"
}

// TODO
// [ ] Find a way to define the D3D12MAAllocator C type
// [ ] Expose more functions/types
// [ ] Move to a 3rdparty collection

CreateAllocator :: proc(pDesc: ^ALLOCATOR_DESC, ppAllocator: ^rawptr) -> windows.HRESULT {
	return D3D12MACreateAllocator(pDesc, ppAllocator)
}

DestroyAllocator :: proc(pAllocator: rawptr) -> u32 {
	if pAllocator != nil {
		return (cast(^windows.IUnknown)pAllocator)->Release()
	}
	return 0
}

CreateResource :: proc(pSelf: rawptr, pAllocDesc: ^ALLOCATION_DESC, pResourceDesc: ^d3d12.RESOURCE_DESC, InitialResourceState: d3d12.RESOURCE_STATES, pOptimizedClearValue: ^d3d12.CLEAR_VALUE, ppAllocation: ^rawptr, riidResource: ^windows.GUID, ppvResource: ^rawptr) -> windows.HRESULT {
	return D3D12MAAllocator_CreateResource(pSelf, pAllocDesc, pResourceDesc, InitialResourceState, pOptimizedClearValue, ppAllocation, riidResource, ppvResource)
}

SetCurrentFrameIndex :: proc(pSelf: rawptr, frame_index: uint) {
	D3D12MAAllocator_SetCurrentFrameIndex(pSelf, frame_index)
}

@(private)
@(default_calling_convention="c")
foreign d3d12ma_c {
	D3D12MACreateAllocator :: proc(pDesc: ^ALLOCATOR_DESC, ppAllocator: ^rawptr) -> windows.HRESULT ---
	D3D12MAAllocator_CreateResource :: proc(pSelf: rawptr, pAllocDesc: ^ALLOCATION_DESC, pResourceDesc: ^d3d12.RESOURCE_DESC, InitialResourceState: d3d12.RESOURCE_STATES, pOptimizedClearValue: ^d3d12.CLEAR_VALUE, ppAllocation: ^rawptr, riidResource: ^windows.GUID, ppvResource: ^rawptr) -> windows.HRESULT ---
	D3D12MAAllocator_SetCurrentFrameIndex :: proc(pSelf: rawptr, frame_index: uint) ---
}

AllocateFunctionType :: proc"c"(size: u64, alignment: u64, pPrivateData: rawptr) -> rawptr
FreeFunctionType :: proc"c"(pMemory: rawptr, pPrivateData: rawptr)

ALLOCATION_CALLBACKS :: struct {
	pAllocate: AllocateFunctionType,
	pFree: FreeFunctionType,
	pPrivateData: rawptr,
}

ALLOCATOR_FLAG :: enum u32 {
	SINGLETHREADED = 0,
	ALWAYS_COMMITTED = 1,
	DEFAULT_POOLS_NOT_ZEROED = 2,
	MSAA_TEXTURES_ALWAYS_COMMITTED = 3,
	DONT_PREFER_SMALL_BUFFERS_COMMITTED = 4,
}
ALLOCATOR_FLAGS :: distinct bit_set[ALLOCATOR_FLAG; u32]

ALLOCATOR_DESC :: struct {
	Flags: ALLOCATOR_FLAGS,
	pDevice: ^d3d12.IDevice,
	PreferredBlockSize: u64,
	pAllocationCallbacks: ^ALLOCATION_CALLBACKS,
	pAdapter: ^dxgi.IAdapter,
}

ALLOCATION_FLAG :: enum u32 {
	COMMITTED = 0,
	NEVER_ALLOCATE = 1,
	WITHIN_BUDGET = 2,
	UPPER_ADDRESS = 3,
	CAN_ALIAS = 4,
	STRATEGY_MIN_MEMORY = 5,
	STRATEGY_MIN_TIME = 6,
	STRATEGY_MIN_OFFSET = 7,
	STRATEGY_BEST_FIT = STRATEGY_MIN_MEMORY,
	STRATEGY_FIRST_FIT = STRATEGY_MIN_TIME,
	// TODO: STRATEGY_MASK = ??
}
ALLOCATION_FLAGS :: distinct bit_set[ALLOCATION_FLAG; u32]

ALLOCATION_DESC :: struct {
	Flags: ALLOCATION_FLAGS,
	HeapType: d3d12.HEAP_TYPE,
	HeapFlags: d3d12.HEAP_FLAGS,
	CustomPool: rawptr,
	pPrivateData: rawptr,
}