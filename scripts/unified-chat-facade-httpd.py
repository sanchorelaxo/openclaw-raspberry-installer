#!/usr/bin/env python3
"""Simple HTTP server for the unified chat facade with debug request logging."""

from __future__ import annotations

import argparse
import functools
import http.server
import logging
import os


class DebugHTTPRequestHandler(http.server.SimpleHTTPRequestHandler):
    """Serve static files and emit request logs at DEBUG level."""

    def log_message(self, format: str, *args) -> None:  # noqa: A003
        logging.getLogger("unified_chat_facade.http").debug(
            "%s - - [%s] %s",
            self.client_address[0],
            self.log_date_time_string(),
            format % args,
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Unified chat facade static HTTP server"
    )
    parser.add_argument("--bind", default="127.0.0.1", help="Bind address")
    parser.add_argument("--port", type=int, default=8787, help="Listen port")
    parser.add_argument(
        "--directory",
        default=os.getcwd(),
        help="Directory to serve",
    )
    parser.add_argument(
        "--log-level",
        default=os.environ.get("UNIFIED_CHAT_FACADE_LOG_LEVEL", "DEBUG"),
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        help="Python logging level",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.DEBUG),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    logger = logging.getLogger("unified_chat_facade")

    handler = functools.partial(DebugHTTPRequestHandler, directory=args.directory)
    server = http.server.ThreadingHTTPServer((args.bind, args.port), handler)

    logger.info(
        "serving unified chat facade on http://%s:%d from %s (log_level=%s)",
        args.bind,
        args.port,
        args.directory,
        args.log_level,
    )

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("shutdown requested")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
