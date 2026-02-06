# RAG (Retrieval-Augmented Generation) Skill

Search and query local documents using vector embeddings and Hailo-accelerated LLM inference.

## test_rag.py
Indexes local documents and answers questions using retrieval-augmented generation.

**Usage:**
```bash
# Run automated test queries
python3 test_rag.py

# Interactive query mode
python3 test_rag.py --interactive
```

**Test mode output:**
- RAG configuration summary
- Document loading and indexing status
- Results for built-in test queries (summarize, main topics)

**Interactive mode:**
- Loads and indexes documents from the data directory
- Accepts free-form questions, answers using retrieved context
- Type `quit` to exit

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
