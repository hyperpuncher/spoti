package library

import "core:sync/chan"
import "core:testing"

@(test)
failed_covers_are_delivered_to_release_pending_markers :: proc(t: ^testing.T) {
	results, err := chan.create_buffered(chan.Chan(Result), 1, context.allocator)
	if err != nil {testing.fail_now(t, "channel")}
	defer chan.destroy(results)
	covers, cover_err := chan.create_buffered(chan.Chan(Cover_Result), 2, context.allocator)
	if cover_err != nil {testing.fail_now(t, "channel")}
	defer chan.destroy(covers)
	client := Client {
		results        = results,
		cover_results  = covers,
		covers_pending = 2,
	}
	defer delete(client.cover_queue)
	_ = chan.send(covers, Cover_Result{key = 1})
	_ = chan.send(covers, Cover_Result{key = 2})
	testing.expect(t, poll(&client))
	testing.expect_value(t, client.covers_pending, 0)
	testing.expect_value(t, len(client.cover_queue), 2)
	first, ok := take_cover(&client)
	testing.expect(t, ok && (first.key == 1 || first.key == 2) && first.image == nil)
	second, received := take_cover(&client)
	testing.expect(
		t,
		received &&
		second.key != first.key &&
		(second.key == 1 || second.key == 2) &&
		second.image == nil,
	)
}
