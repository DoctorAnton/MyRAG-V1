# MyRAG 工程化版本说明

这个版本把原来的入门版 RAG 代码整理成三层：

```text
app/       核心代码
configs/   文档配置
scripts/   可运行脚本
```

## 1. 核心目录

```text
app/settings.py
```
集中管理 MySQL、Milvus、Embedding、DeepSeek 配置。

```text
app/schemas.py
```
放统一数据结构，例如 `DocumentSpec` 和 `Chunk`。

```text
app/storage/mysql_store.py
```
负责 MySQL：保存文档信息、chunk 原文、chunk 和 Milvus 的映射。

```text
app/storage/milvus_store.py
```
负责 Milvus：保存向量，按向量相似度检索 chunk_id。

```text
app/embedding/embedder.py
```
负责把文本转成 1024 维向量，默认使用 `BAAI/bge-large-zh-v1.5`。

```text
app/ingest/loaders.py
```
负责读取 PDF 文本。

```text
app/ingest/splitters.py
```
负责切块。目前支持两种：

- `report`：技术报告，按章节/小节切。
- `health_archive`：健康档案，先按患者切，再按 7 个栏目切。

```text
app/ingest/pipeline.py
```
完整入库流水线：读取配置 -> 抽文本 -> 切块 -> embedding -> 写 MySQL 和 Milvus。

```text
app/rag/`
```
问答系统：检索、prompt、LLM、简单问题路由。

## 2. 文档配置

配置文件在：

```text
configs/documents.yaml
```

大白话：新增文档时，优先改这个文件，不要去改核心代码。

```yaml
- enabled: true # 是否入库
  path: D:\MyAgent\MyRAG\Milvus\健康档案.pdf
  doc_id: doc_health_archive # 文档唯一编号
  title: 健康档案 
  doc_type: health_record # 文档类型
  splitter: health_archive # 使用哪种切块器
  start_page: 1 # 从 PDF 第几页开始抽文本
```

含义：

```text
enabled=true：这篇文档要入库。
doc_id：整篇文档的唯一编号，不能重复。
doc_type：文档类型，例如 technical_report、health_record。
splitter：使用哪种切块器。
start_page：从 PDF 第几页开始抽文本。
```

## 3. 健康档案怎么切

健康档案不是普通技术报告。它的结构是：

```text
同一份 PDF
里面有多个患者
每个患者都有 7 个栏目
```

所以切块顺序是：

```text
先分患者
再分栏目
栏目太长再二级切块
```

最终 chunk 类似：

```text
patient_001 + 一、基本信息
patient_001 + 二、医疗历史
patient_001 + 三、生活方式和习惯
...
patient_002 + 一、基本信息
```

这样可以避免不同患者的信息混在一起。

## 4. 运行入库

确保 Docker 中 MySQL 和 Milvus 正在运行，然后执行：

```powershell
D:\Anaconda3\envs\py311\python.exe D:\MyAgent\MyRAG\Milvus\scripts\ingest_documents.py
```

当前 `documents.yaml` 默认只启用了 `健康档案.pdf`。

## 5. 查看当前数据

```powershell
D:\Anaconda3\envs\py311\python.exe D:\MyAgent\MyRAG\Milvus\scripts\inspect_store.py
```

## 6. 启动问答

```powershell
D:\Anaconda3\envs\py311\python.exe D:\MyAgent\MyRAG\Milvus\scripts\rag_chat.py
```

## 7. 新增文档

技术报告：

```yaml
- enabled: true
  path: D:\MyAgent\MyRAG\Milvus\新技术报告.pdf
  doc_id: doc_new_report
  title: 新技术报告
  doc_type: technical_report
  splitter: report
  start_page: 1
  skip_references: true
```

健康档案：

```yaml
- enabled: true
  path: D:\MyAgent\MyRAG\Milvus\新的健康档案.pdf
  doc_id: doc_new_health_archive
  title: 新的健康档案
  doc_type: health_record
  splitter: health_archive
  start_page: 1
```

## 8. 注意事项

- `doc_id` 必须唯一。
- MySQL 的 `document_chunks` 表需要有 `doc_type`、`case_id`、`section_name`、`page_start`、`page_end`、`metadata_json` 字段。
- `documents` 表需要有 `doc_type` 字段。
- Milvus collection 继续使用 `rag_chunks`，已有 collection 不必立刻重建。
- 医疗类数据如果是真实数据，建议先脱敏再入库。

## 10. Query Rewriter + LCEL 编排

当前项目已经加入两个新模块：

```text
app/rag/query_rewriter.py
app/rag/lcel_chain.py
```

它们和原来的 `ChatMemoryStore` 是配合关系，不是替代关系。

### 10.1 为什么需要 Query Rewriter

用户在多轮对话里经常会这样问：

```text
那医生建议呢？
之前那个患者还有什么风险？
这个指标说明什么？
```

这些问题本身不完整，因为里面有：

```text
那
之前那个患者
这个指标
```

如果直接拿这种问题去 Milvus 检索，效果可能不好。

所以现在流程变成：

```text
读取历史对话
-> 用 LLM 判断当前问题是否依赖历史
-> 把追问改写成独立问题
-> 用独立问题去检索和回答
```

例子：

```text
历史：用户刚问过“张三的健康风险是什么？”
当前问题：那医生建议呢？
改写后：张三的医生建议是什么？
```

### 10.2 原始问题和改写问题分别怎么用

系统会保留两种问题：

```text
original_question
standalone_question
```

大白话：

```text
original_question = 用户真实输入的话
standalone_question = 系统改写后的独立问题
```

使用方式：

```text
保存到 MySQL 的 user 消息：使用 original_question
Milvus 检索：使用 standalone_question
最终回答 prompt：使用 standalone_question
assistant 的 metadata_json：保存 original_question 和 standalone_question
```

这样做的好处是：

```text
既保留用户真实说法，方便审计和回放；
又用更清楚的问题做检索和回答，提高准确率。
```

### 10.3 LCEL 在这里做什么

LCEL 是 LangChain 的链式编排方式。

当前项目采用的是“轻量 LCEL 方案”：

```text
不让 LangChain 接管 MySQL
不让 LangChain 接管 Milvus
不让 LangChain 接管 ChatMemoryStore
只用 LCEL 把 RAG 主链串起来
```

当前 LCEL 链在：

```text
app/rag/lcel_chain.py
```

它做三步：

```text
1. 接收 standalone_question
2. 调用 Retriever，从 Milvus 找 chunk_id，再从 MySQL 拿原文
3. 调用 LLM，基于参考资料生成回答
```

也就是：

```text
standalone_question
-> retriever.retrieve()
-> build_answer_prompt()
-> llm.chat()
```

### 10.4 为什么继续保留 ChatMemoryStore

`ChatMemoryStore` 在：

```text
app/memory/memory_store.py
```

它继续负责：

```text
新建会话
列出历史会话
保存 user 消息
保存 assistant 消息
读取最近 N 轮历史
```

没有改成 LangChain 的 `SQLChatMessageHistory`，原因是：

```text
企业项目通常有自己的表结构要求。
例如 user_id、conversation_id、metadata_json、审计字段、权限字段等。
自己维护 ChatMemoryStore 更可控。
```

### 10.5 现在一轮问答完整流程

有记忆版问答现在是：

```text
1. 用户输入原始问题 original_question
2. qa.py 根据 conversation_id 从 MySQL 读取最近 N 轮历史
3. query_rewriter.py 调用 LLM，生成 standalone_question
4. lcel_chain.py 用 standalone_question 做 RAG 检索和回答
5. qa.py 保存 original_question 到 chat_messages
6. qa.py 保存 assistant answer 到 chat_messages
7. assistant 的 metadata_json 里保存 chunk_ids、standalone_question、need_history、rewrite_reason
```

### 10.6 需要注意

引入 rewriter 后，每个普通 RAG 问题通常会多一次 LLM 调用：

```text
第一次：改写问题
第二次：生成最终回答
```

好处是多轮追问更稳。

代价是：

```text
响应慢一点
调用成本高一点
```

后续可以继续优化：

```text
先用关键词判断是否可能需要历史，只有需要时才调用 rewriter。
```

## 11. 瘦身后的三路由：Memory / Metadata / RAG

这次我们把系统从“四路由”收缩成“三路由”：

```text
memory
metadata
rag
```

之前讨论过的 `structured` 暂时不放在当前 RAG 项目里做。

大白话：

```text
当前项目只做“会记忆、会改写、能查基础资料库概览的 RAG 系统”。
复杂结构化数据库查询以后单独做成 NL2SQL Tool，而不是塞进 RAG 主链。
```

### 11.1 为什么要瘦身

如果继续支持：

```text
有哪些患者？
有哪些章节？
某文档结构如何？
王五在哪篇文档中？
谁的血糖最高？
```

这些问题会把系统推向：

```text
自然语言 -> SQL 查询计划 -> SQL 执行 -> 结果总结
```

这已经是 NL2SQL / SQL Tool 的工作，不是 RAG 主链应该承担的工作。

如果在 RAG 里靠 `if/else` 硬补这些问题，代码会越来越散，最终很难维护。

所以现在边界改成：

```text
RAG：负责正文语义问答。
Memory：负责聊天历史。
Metadata：只负责非常基础的资料库总账。
NL2SQL：以后单独做 Tool，目前不做。
```

### 11.2 三个路由分别做什么

```text
memory
```

回答聊天历史本身。

例如：

```text
我刚刚问的是谁？
你刚才回答了什么？
我们前面聊到哪里了？
```

它只看 MySQL 的 `chat_messages`，不查 Milvus。

相关代码：

```text
app/rag/memory_answer.py
app/memory/memory_store.py
```

---

```text
metadata
```

只回答三类固定的资料库基础概览。

当前明确支持：

```text
1. 有几篇文档
2. 有哪些文档
3. 有哪些文档类型
```

对应示例：

```text
资料库有几篇文档？
现在资料库里面有哪些文档？
资料库有哪些文档类型？
```

它主要查 MySQL 的 `documents` 表和 `document_chunks` 的基础统计。

相关代码：

```text
app/rag/metadata_answer.py
app/storage/mysql_store.py
```

---

```text
rag
```

回答知识库正文内容。

例如：

```text
张三九有什么健康风险？
他的既往病史有哪些？
量子计算报告主要讲了什么？
AI Agent 报告如何解释工具调用？
```

它会走：

```text
必要时问题改写
-> Milvus 检索 chunk_id
-> MySQL 取 chunk 原文
-> LLM 基于原文回答
```

相关代码：

```text
app/rag/query_rewriter.py
app/rag/lcel_chain.py
app/rag/retriever.py
app/rag/prompt.py
```

### 11.3 哪些问题当前故意不支持

下面这些属于结构化数据库查询，当前 RAG 系统不做精确统计：

```text
有哪些患者？
有哪些章节？
某文档结构如何？
王五在哪篇文档中？
某个患者有哪些栏目？
谁的血糖最高？
```

系统会统一回答类似：

```text
这个问题属于结构化数据库查询，需要通过单独的 NL2SQL / SQL Tool 精确处理。
当前这个 RAG 系统只支持三类基础资料库概览：
1. 有几篇文档
2. 有哪些文档
3. 有哪些文档类型
```

这不是系统坏了，而是当前项目的边界设计。

以后如果要做这些问题，建议做成 Agent Workflow 里的独立工具：

```text
sql_query_tool / nl2sql_tool
```

不要继续塞进 RAG 主链。

### 11.4 Router 如何判断

路由器在：

```text
app/rag/query_router.py
```

它采用：

```text
规则优先 + LLM 兜底
```

大白话：

```text
特别明确的问题，用代码规则直接判断；
模糊问题，再让 LLM 判断答案来源。
```

固定 metadata 问题直接走规则：

```text
有几篇文档 -> metadata / count_documents
有哪些文档 -> metadata / list_documents
有哪些文档类型 -> metadata / list_doc_types
```

复杂结构化问题也会被规则拦住，但不会执行复杂 SQL：

```text
有哪些患者 -> metadata / unsupported_structured
有哪些章节 -> metadata / unsupported_structured
某实体在哪篇文档 -> metadata / unsupported_structured
```

普通正文问题走 RAG：

```text
张三九有什么健康风险？ -> rag
他的既往病史有哪些？ -> rag + rewriter
```

历史问题走 memory：

```text
我刚刚问的是谁？ -> memory
我们刚刚聊到哪里了？ -> memory
```

### 11.5 什么时候调用 Rewriter

问题改写仍然保留，但只服务于 RAG。

不会改写：

```text
memory 问题
metadata 问题
unsupported_structured 问题
```

会改写：

```text
route = rag
并且 Router 判断 need_rewrite = true
```

例子：

```text
他的既往病史有哪些？
```

如果前文聊的是张三九，rewriter 会尽量改成：

```text
张三九的既往病史有哪些？
```

然后再去 Milvus 检索。

### 11.6 现在 qa.py 的完整流程

主入口在：

```text
app/rag/qa.py
```

流程是：

```text
用户输入问题
↓
读取最近 N 轮聊天历史
↓
QueryRouter 判断 route / intent / need_rewrite
↓
如果 route=rag 且 need_rewrite=true，调用 QueryRewriter
↓
按 route 分发：
  memory   -> MemoryAnswerer
  metadata -> MetadataAnswer
  rag      -> LCELRAGChain
↓
保存 user 原始问题和 assistant 回答到 chat_messages
↓
assistant 的 metadata_json 里记录 route、intent、standalone_question、chunk_ids
```

### 11.7 推荐阅读顺序

如果你想读懂瘦身后的系统，建议按这个顺序：

```text
1. app/rag/query_router.py
```

先看系统如何判断 memory / metadata / rag。

```text
2. app/rag/qa.py
```

再看主流程如何分发。

```text
3. app/rag/metadata_answer.py
```

看 metadata 固定支持哪三类问题，以及不支持结构化查询时如何提示。

```text
4. app/rag/memory_answer.py
```

看聊天历史问题怎么回答。

```text
5. app/rag/query_rewriter.py
```

看 RAG 追问如何改写。

```text
6. app/rag/lcel_chain.py
```

最后看普通 RAG 问答如何执行检索和生成。

### 11.8 被删掉的内容

为了减少混乱，下面两个文件已经删除：

```text
app/rag/structured_query.py
app/rag/router.py
```

原因：

```text
structured_query.py 会把系统带向 NL2SQL，不适合继续放在当前 RAG 主链里。
router.py 名字容易和 query_router.py 混淆，它原本只是 metadata 回答函数，所以改成了 metadata_answer.py。
```

## 12. Qwen 流式输出说明

当前模型调用已经切到 OpenAI 兼容形式，可以连接阿里云百炼 Qwen。

注意：

```text
app/settings.py 只放配置
app/rag/llm.py 负责模型调用
app/rag/qa.py 负责问答流程和保存完整答案
scripts/rag_chat_memory.py 负责终端打印
```

### 12.1 settings.py 放什么

你已经在 `app/settings.py` 配置了：

```text
qwen_api_key
qwen_base_url
qwen_model
```

这部分只负责告诉系统：

```text
用哪个 key
请求哪个 base_url
调用哪个 model
```

不要在 `settings.py` 里写模型请求循环，也不要在里面处理 stream。

### 12.2 llm.py 做什么

模型调用在：

```text
app/rag/llm.py
```

里面有两个方法：

```text
chat()
```

普通非流式调用。

用于：

```text
Router
Rewriter
MemoryAnswerer
非流式 RAG
```

这些步骤需要稳定拿到完整文本，尤其 Router 和 Rewriter 经常要解析 JSON，所以不适合流式。

```text
stream_chat()
```

流式调用。

用于最终 RAG 回答，让终端可以边生成边显示。

这里显式设置：

```python
extra_body={"enable_thinking": False}
```

所以不会展示 `reasoning_content`，只输出最终答案正文。

### 12.3 qa.py 做什么

问答入口在：

```text
app/rag/qa.py
```

现在有两个入口：

```text
ask()
```

普通一次性问答。

```text
stream_ask()
```

流式问答。

大白话：

```text
Router / Rewriter 还是先正常执行
如果最终走 RAG，就流式生成答案
终端一边打印，程序一边把答案拼起来
模型结束后，再把完整 answer 一次性写入 MySQL
```

不要每生成一个字就写一次 MySQL，这样会很慢，也容易留下半截回答。

### 12.4 终端脚本做什么

终端脚本在：

```text
scripts/rag_chat_memory.py
```

它调用：

```text
qa.stream_ask()
```

收到：

```text
answer_delta
```

就立刻打印。

收到：

```text
done
```

说明回答结束，然后再显示引用 chunk。

### 12.5 为什么不展示思考链

阿里云百炼 Qwen 的流式结果里可能有：

```text
reasoning_content
content
```

当前项目只打印：

```text
content
```

不打印：

```text
reasoning_content
```

原因：

```text
企业级系统一般不直接展示完整思考链。
更推荐展示 route、standalone_question、chunk_ids 这类可审计执行轨迹。
```

如果以后你想做调试面板，可以加一个 trace/debug 模式，而不是默认暴露思考链。

