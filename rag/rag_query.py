#!/usr/bin/env python3
"""
RAG (Retrieval-Augmented Generation) query engine for OpenClaw on Raspberry Pi.
Uses Hailo-accelerated models via hailo-ollama for local inference.

Usage:
  # Single query via CLI argument
  python3 rag_query.py "What is this document about?"

  # Interactive mode
  python3 rag_query.py --interactive

  # Query via stdin
  echo "Summarize this document" | python3 rag_query.py
"""

import argparse
import os
import sys
from pathlib import Path

from llama_index.core import VectorStoreIndex, SimpleDirectoryReader, Settings
from llama_index.embeddings.ollama import OllamaEmbedding
from llama_index.llms.ollama import Ollama


def get_config():
    """Load configuration from environment or defaults"""
    return {
        "ollama_base_url": os.getenv("OLLAMA_BASE_URL", "http://localhost:8000"),
        "llm_model": os.getenv("HAILO_MODEL", "qwen2:1.5b"),
        "embed_model": "nomic-embed-text",
        "data_dir": os.getenv("RAG_DATA_DIR", os.path.expanduser("~/.openclaw/rag_documents")),
        "request_timeout": 300.0,
        "temperature": 0.1,
        "chunk_size": 1024,
        "chunk_overlap": 200,
        "similarity_top_k": 3,
    }


def initialize_models(config):
    """Initialize embedding and LLM models"""
    
    embed_model = OllamaEmbedding(
        model_name=config["embed_model"],
        base_url=config["ollama_base_url"],
        request_timeout=config["request_timeout"],
    )
    
    llm = Ollama(
        model=config["llm_model"],
        base_url=config["ollama_base_url"],
        request_timeout=config["request_timeout"],
        temperature=config["temperature"],
    )
    
    Settings.embed_model = embed_model
    Settings.llm = llm
    Settings.chunk_size = config["chunk_size"]
    Settings.chunk_overlap = config["chunk_overlap"]
    
    return embed_model, llm


def load_and_index_documents(data_dir, embed_model):
    """Load documents and create vector index"""
    
    data_path = Path(data_dir)
    
    if not data_path.exists():
        raise FileNotFoundError(f"Data directory '{data_dir}' not found.")
    
    docs = SimpleDirectoryReader(str(data_path)).load_data()
    
    if not docs:
        raise ValueError(f"No documents found in {data_dir}")
    
    print(f"Loaded {len(docs)} document(s) from {data_dir}")
    
    index = VectorStoreIndex.from_documents(docs, embed_model=embed_model)
    
    return index


def create_query_engine(index, llm, similarity_top_k=3):
    """Create query engine with specified retrieval parameters"""
    
    query_engine = index.as_query_engine(
        llm=llm,
        similarity_top_k=similarity_top_k,
        response_mode="compact"
    )
    
    return query_engine


class RAGEngine:
    """Reusable RAG engine that can be initialized once and queried multiple times."""

    def __init__(self, config=None):
        self.config = config or get_config()
        self.embed_model, self.llm = initialize_models(self.config)
        self.index = load_and_index_documents(self.config["data_dir"], self.embed_model)
        self.query_engine = create_query_engine(
            self.index, self.llm, self.config["similarity_top_k"]
        )

    def query(self, question):
        """Run a single query and return the response object."""
        return self.query_engine.query(question)

    def query_str(self, question):
        """Run a single query and return the response as a string."""
        return str(self.query(question))

    def batch_query(self, questions):
        """Run multiple queries. Returns list of (question, response_str, error) tuples."""
        results = []
        for q in questions:
            try:
                results.append((q, self.query_str(q), None))
            except Exception as e:
                results.append((q, None, str(e)))
        return results


def interactive_mode(engine):
    """Run interactive query mode"""
    print("\nRAG system ready. Type 'quit' to exit.")
    print("-" * 40)

    while True:
        try:
            question = input("\nYour question: ").strip()

            if question.lower() in ['quit', 'exit', 'q']:
                print("Goodbye!")
                break

            if not question:
                continue

            response = engine.query(question)
            print(f"\nAnswer: {response}")

        except KeyboardInterrupt:
            print("\nGoodbye!")
            break
        except Exception as e:
            print(f"Error: {str(e)}")


def main():
    parser = argparse.ArgumentParser(
        description="Query local documents using RAG with Hailo-accelerated inference."
    )
    parser.add_argument(
        "query", nargs="?", default=None,
        help="Query string. Omit for interactive mode or pipe via stdin."
    )
    parser.add_argument(
        "--interactive", "-i", action="store_true",
        help="Run in interactive mode"
    )
    args = parser.parse_args()

    config = get_config()
    print(f"RAG Configuration:")
    print(f"  Ollama URL: {config['ollama_base_url']}")
    print(f"  LLM Model: {config['llm_model']}")
    print(f"  Embed Model: {config['embed_model']}")
    print(f"  Data Dir: {config['data_dir']}")
    print()

    print("Initializing RAG engine...")
    engine = RAGEngine(config)

    if args.interactive:
        interactive_mode(engine)
    elif args.query:
        response = engine.query(args.query)
        print(f"\n{response}")
    elif not sys.stdin.isatty():
        question = sys.stdin.read().strip()
        if question:
            response = engine.query(question)
            print(f"\n{response}")
        else:
            print("No query provided on stdin.", file=sys.stderr)
            sys.exit(1)
    else:
        interactive_mode(engine)


if __name__ == "__main__":
    main()
