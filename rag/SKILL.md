# RAG (Retrieval-Augmented Generation) Skill

Search and query local documents using vector embeddings and Hailo-accelerated LLM inference.

## rag_query.py
Reusable RAG engine that accepts queries dynamically.

**Usage:**
```bash
# Single query via CLI argument
python3 rag_query.py "What is this document about?"

# Interactive mode
python3 rag_query.py --interactive

# Query via stdin
echo "Summarize this document" | python3 rag_query.py
```

**Programmatic usage (from Python):**
```python
from rag_query import RAGEngine

engine = RAGEngine()
answer = engine.query_str("What is this document about?")
results = engine.batch_query(["Question 1", "Question 2"])
```

## test_rag.py
Runs predefined test queries against the RAG engine to verify the pipeline works.

**Usage:**
```bash
python3 test_rag.py
```

## Configuration

Environment variables (all optional, sensible defaults provided):

| Variable | Default | Description |
|---|---|---|
| `OLLAMA_BASE_URL` | `http://localhost:8000` | hailo-ollama server URL |
| `HAILO_MODEL` | `qwen2:1.5b` | LLM model for generation |
| `RAG_DATA_DIR` | `~/.openclaw/rag_documents` | Directory of documents to index |

## Supported Document Formats
PDF, TXT, MD, DOCX, and other formats supported by llama-index SimpleDirectoryReader.

## Dependencies

Location: `rag/requirements.txt`

Install:
```bash
pip install -r rag/requirements.txt
```
