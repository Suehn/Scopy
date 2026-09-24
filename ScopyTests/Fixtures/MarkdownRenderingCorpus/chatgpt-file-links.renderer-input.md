这个 repo 的分层说明写得很清楚：[docs/chatgpt_text_raw_stream_reference.md](/Users/alice/project/docs/guide_v2.md:25)

这类代码的核心入口就是 [src/backend/adapter/chatgpt_text.js](/Users/alice/project/src/backend/adapter/chatgpt_text.js:944)。

一次 turn 可能同时经过 `main SSE + handoff + websocket + snapshot`。
