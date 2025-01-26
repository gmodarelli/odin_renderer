package renderer

import "core:fmt"
import "core:sync"
import windows "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

@(private="package")
Queue :: struct {
	type: d3d12.COMMAND_LIST_TYPE,
	queue: ^d3d12.ICommandQueue,
	fence: ^d3d12.IFence,
	next_fence_value: u64,
	last_completed_fence_value: u64,
	fence_event_handle: windows.HANDLE,
	fence_mutex: sync.Mutex,
	event_mutex: sync.Mutex,
}

@(private="package")
queue_create :: proc(queue: ^Queue, type: d3d12.COMMAND_LIST_TYPE, debug_name: string) {
	queue.next_fence_value = 1
	queue.type = type

	desc := d3d12.COMMAND_QUEUE_DESC{
		Type = type,
	}

	hr := rctx.device->CreateCommandQueue(&desc, d3d12.ICommandQueue_UUID, cast(^rawptr)&queue.queue);
	check_hr(hr, "Failed to create command queue")

	when ODIN_DEBUG {
		queue.queue->SetName(windows.utf8_to_wstring(debug_name))
	}

	hr = rctx.device->CreateFence(0, {}, d3d12.IFence_UUID, cast(^rawptr)&queue.fence)
	check_hr(hr, "Failed to create fence")
	queue.fence_event_handle = windows.CreateEventW(nil, false, false, nil)
	assert(queue.fence_event_handle != windows.INVALID_HANDLE_VALUE, "Failed to create event handle")
}

@(private="package")
queue_destroy :: proc(queue: ^Queue) {
	windows.CloseHandle(queue.fence_event_handle)

	if queue.queue != nil {
		queue.queue->Release()
		queue.queue = nil
	}

	if queue.fence != nil {
		queue.fence->Release()
		queue.fence = nil
	}
}

@(private="package")
queue_wait_for_idle :: proc(queue: ^Queue) {
	queue_wait_for_fence_cpu_blocking(queue, queue.next_fence_value - 1)
}

@(private="package")
queue_wait_for_fence_cpu_blocking :: proc(queue: ^Queue, fence_value: u64) {
	if is_fence_complete(queue, fence_value) { return }

	if sync.mutex_guard(&queue.event_mutex) {
		queue.fence->SetEventOnCompletion(fence_value, queue.fence_event_handle)
		windows.WaitForSingleObject(queue.fence_event_handle, windows.INFINITE)
		queue.last_completed_fence_value = fence_value
	}
}

@(private="package")
queue_execute_command_list :: proc(queue: ^Queue, cmd: ^d3d12.ICommandList) -> u64 {
	hr := (cast(^d3d12.IGraphicsCommandList)cmd)->Close()
	check_hr(hr, "Failed to close command list")

	cmd_lists := [?]^d3d12.IGraphicsCommandList { cast(^d3d12.IGraphicsCommandList)cmd }
	queue.queue->ExecuteCommandLists(len(cmd_lists), (^^d3d12.ICommandList)(&cmd_lists[0]))

	return queue_signal_fence(queue)
}

@(private="package")
queue_signal_fence :: proc(queue: ^Queue) -> u64 {
	fence_value: u64 = 0
	if sync.mutex_guard(&queue.fence_mutex) {
		queue.queue->Signal(queue.fence, queue.next_fence_value)
		queue.next_fence_value += 1
		fence_value = queue.next_fence_value - 1
	}

	return fence_value
}

@(private="file")
insert_wait :: proc(queue: ^Queue, fence_value: u64) {
	queue.queue->Wait(queue.fence, fence_value)
}

@(private="file")
insert_wait_for_queue_fence :: proc(queue: ^Queue, other_queue: ^Queue, fence_value: u64) {
	queue.queue->Wait(other_queue.fence, fence_value)
}

@(private="file")
insert_wait_for_queue :: proc(queue: ^Queue, other_queue: ^Queue) {
	queue.queue->Wait(other_queue.fence, other_queue.next_fence_value)
}

@(private="file")
is_fence_complete :: proc(queue: ^Queue, fence_value: u64) -> bool {
	if fence_value > queue.last_completed_fence_value {
		poll_current_fence_value(queue)
	}

	return fence_value <= queue.last_completed_fence_value
}

@(private="file")
poll_current_fence_value :: proc(queue: ^Queue) -> u64 {
	completed_value := queue.fence->GetCompletedValue()
	if queue.last_completed_fence_value < completed_value {
		queue.last_completed_fence_value = completed_value
	}
	
	return queue.last_completed_fence_value
}