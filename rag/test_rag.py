#!/usr/bin/env python3
"""
Test suite for the RAG query engine.
Imports RAGEngine from rag_query and runs predefined test queries.
"""

import sys
from rag_query import RAGEngine


TEST_QUERIES = [
    "Summarize this document in 3 lines",
    "What are the main topics covered in these documents?",
]


def run_tests():
    print("Initializing RAG engine for testing...")
    engine = RAGEngine()

    print("\n" + "=" * 50)
    print("RAG System Test Results")
    print("=" * 50)

    results = engine.batch_query(TEST_QUERIES)
    all_passed = True

    for i, (question, response, error) in enumerate(results, 1):
        print(f"\nTest {i}: {question}")
        print("-" * 40)

        if error:
            print(f"Error: {error}")
            print("Status: FAILED")
            all_passed = False
        else:
            print(f"Response: {response}")
            print("Status: SUCCESS")

        print("-" * 40)

    return all_passed


if __name__ == "__main__":
    print("Starting RAG Pipeline Test...")
    success = run_tests()

    if success:
        print("\nAll tests passed!")
        print("Run rag_query.py for dynamic queries:")
        print('  python3 rag_query.py "Your question here"')
        print("  python3 rag_query.py --interactive")
    else:
        print("\nSome tests failed. Check the error messages above.")
        sys.exit(1)
