#!/usr/bin/env python3
"""
RAG (Retrieval-Augmented Generation) test script for OpenClaw on Raspberry Pi.
Uses Hailo-accelerated models via hailo-ollama for local inference.
"""

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


def test_rag_system():
    """Test the RAG system with sample queries"""
    
    config = get_config()
    
    print(f"RAG Configuration:")
    print(f"  Ollama URL: {config['ollama_base_url']}")
    print(f"  LLM Model: {config['llm_model']}")
    print(f"  Embed Model: {config['embed_model']}")
    print(f"  Data Dir: {config['data_dir']}")
    print()
    
    try:
        print("Initializing models...")
        embed_model, llm = initialize_models(config)
        
        print("Loading and indexing documents...")
        index = load_and_index_documents(config["data_dir"], embed_model)
        
        print("Creating query engine...")
        query_engine = create_query_engine(index, llm, config["similarity_top_k"])
        
        test_queries = [
            "Summarize this document in 3 lines",
            "What are the main topics covered in these documents?",
        ]
        
        print("\n" + "=" * 50)
        print("RAG System Test Results")
        print("=" * 50)
        
        for i, query in enumerate(test_queries, 1):
            print(f"\nTest {i}: {query}")
            print("-" * 40)
            
            try:
                response = query_engine.query(query)
                print(f"Response: {response}")
                print("Status: SUCCESS")
            except Exception as e:
                print(f"Error: {str(e)}")
                print("Status: FAILED")
            
            print("-" * 40)
        
        return True
        
    except Exception as e:
        print(f"System Error: {str(e)}")
        return False


def interactive_mode():
    """Run interactive query mode"""
    
    config = get_config()
    
    print("Initializing RAG system...")
    embed_model, llm = initialize_models(config)
    index = load_and_index_documents(config["data_dir"], embed_model)
    query_engine = create_query_engine(index, llm, config["similarity_top_k"])
    
    print("\nRAG system ready. Type 'quit' to exit.")
    print("-" * 40)
    
    while True:
        try:
            query = input("\nYour question: ").strip()
            
            if query.lower() in ['quit', 'exit', 'q']:
                print("Goodbye!")
                break
            
            if not query:
                continue
            
            response = query_engine.query(query)
            print(f"\nAnswer: {response}")
            
        except KeyboardInterrupt:
            print("\nGoodbye!")
            break
        except Exception as e:
            print(f"Error: {str(e)}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--interactive":
        interactive_mode()
    else:
        print("Starting RAG Pipeline Test...")
        success = test_rag_system()
        
        if success:
            print("\nRAG system is working correctly!")
            print("Run with --interactive for interactive query mode.")
        else:
            print("\nRAG system test failed. Check the error messages above.")
            sys.exit(1)
