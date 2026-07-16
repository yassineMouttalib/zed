//! Native agent tool that physically compacts the running thread's context.
//!
//! Unlike the summary-based `Thread::compact`, this deletes redundant blocks
//! (old thinking, old tool inputs/results, redundant `raw_input`) directly from
//! the in-memory messages via `Thread::compact_physical`. Because it mutates the
//! live `Thread` and notifies, the reduction takes effect immediately for the
//! next model request and is persisted through the normal save path.

use crate::{AgentTool, Thread, ToolCallEventStream, ToolInput};
use agent_client_protocol::schema::v1 as acp;
use gpui::{App, Task, WeakEntity};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

/// Physically shrink this session's context by deleting blocks the model never
/// needs to re-read. NOT a summary — actual deletion. Preserves every user
/// message and all agent-authored text; keeps the last `keep_last_n_tool_results`
/// tool call/result pairs and a factual working-context map of files explored.
///
/// By default ALL thinking/reasoning blocks are stripped from every assistant
/// message — thinking is intermediate scratch that has no value once the
/// assistant has produced its visible output. Set `strip_all_thinking` to false
/// to preserve thinking on the last `keep_last_n_turns` steps.
#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct CompactThreadToolInput {
    /// Number of recent assistant steps whose thinking is kept intact when
    /// `strip_all_thinking` is false. Default 3.
    #[serde(default = "default_keep_last_n_turns")]
    pub keep_last_n_turns: u32,
    /// Number of recent tool call/result *pairs* to preserve (recent context +
    /// in-context tool examples). Older tool inputs/results are elided. Default 5.
    #[serde(default = "default_keep_last_n_tool_results")]
    pub keep_last_n_tool_results: u32,
    /// When true (default), strip ALL thinking/reasoning blocks from every
    /// assistant message. Thinking is intermediate scratch — once the assistant
    /// has produced its visible text, the reasoning chain has no value for
    /// future turns. Set to false to preserve thinking on the last
    /// `keep_last_n_turns` steps.
    #[serde(default = "default_strip_all_thinking")]
    pub strip_all_thinking: bool,
}

fn default_keep_last_n_turns() -> u32 {
    3
}

fn default_keep_last_n_tool_results() -> u32 {
    5
}

fn default_strip_all_thinking() -> bool {
    true
}

pub struct CompactThreadTool {
    thread: WeakEntity<Thread>,
}

impl CompactThreadTool {
    pub fn new(thread: WeakEntity<Thread>) -> Self {
        Self { thread }
    }
}

impl AgentTool for CompactThreadTool {
    type Input = CompactThreadToolInput;
    type Output = String;

    const NAME: &'static str = "compact_thread";

    fn kind() -> acp::ToolKind {
        acp::ToolKind::Other
    }

    fn initial_title(
        &self,
        _input: Result<Self::Input, serde_json::Value>,
        _cx: &mut App,
    ) -> ui::SharedString {
        "Compact session".into()
    }

    fn run(
        self: Arc<Self>,
        input: ToolInput<Self::Input>,
        _: ToolCallEventStream,
        cx: &mut App,
    ) -> Task<Result<Self::Output, Self::Output>> {
        let thread = self.thread.clone();
        cx.spawn(async move |cx| {
            let input = input.recv().await.map_err(|e| e.to_string())?;
            let keep_turns = input.keep_last_n_turns as usize;
            let keep_tools = input.keep_last_n_tool_results as usize;
            let strip_all = input.strip_all_thinking;

            let stats = cx
                .update(|cx| {
                    thread.update(cx, |thread, cx| {
                        thread.compact_physical(keep_turns, keep_tools, strip_all, cx)
                    })
                })
                .map_err(|e| e.to_string())?;

            Ok(format!(
                "I'll reduce the size of this session so I can focus more on tasks \
                 left. I will not jump to conclusion, we didn't finish yet.\n\n\
                 Compacted the live thread in memory (takes effect now). \
                 thinking_removed={}, raw_input_cleared={}, tool_input_elided={}, \
                 reasoning_details_dropped={}, tool_results_trimmed={}, \
                 working_context={}, agent_messages={}, user_messages={} (preserved).",
                stats.thinking_removed,
                stats.raw_input_cleared,
                stats.tool_input_elided,
                stats.reasoning_details_dropped,
                stats.tool_results_trimmed,
                stats.working_context_added,
                stats.agent_messages,
                stats.user_messages,
            ))
        })
    }
}
