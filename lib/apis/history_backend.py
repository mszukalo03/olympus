# app.py
# Enhanced Flask API for managing AI chatbot conversation data with:
# - Pagination
# - Embedding storage & similarity search (pgvector)
# - Export endpoint
# - Optional model_name & embedding fields
# - CORS support
# - Consistent JSON error responses

import os
import json
from typing import Optional, Tuple, List

from flask import Flask, request, jsonify, Response
from dotenv import load_dotenv
import psycopg2
from psycopg2.extras import RealDictCursor
from flask_cors import CORS

# --- Environment Setup ---
load_dotenv()

app = Flask(__name__)
CORS(app, resources={r"/*": {"origins": [o.strip() for o in os.getenv("ALLOWED_ORIGINS", "*").split(",")]}})

# --- Helpers ---
def get_db_connection():
    """Establishes a connection to the PostgreSQL database."""
    try:
        conn = psycopg2.connect(
            host=os.environ.get("DB_HOST"),
            database=os.environ.get("DB_NAME"),
            user=os.environ.get("DB_USER"),
            password=os.environ.get("DB_PASSWORD"),
            port=os.environ.get("DB_PORT")
        )
        return conn
    except psycopg2.OperationalError as e:
        app.logger.error(f"Database connection failed: {e}")
        return None

def parse_pagination() -> Tuple[int, int]:
    """Extracts (limit, offset) from query params page & page_size (1-based page)."""
    try:
        page_size = int(request.args.get("page_size", 20))
        page = int(request.args.get("page", 1))
    except ValueError:
        page_size, page = 20, 1
    page_size = max(1, min(page_size, 200))
    page = max(1, page)
    offset = (page - 1) * page_size
    return page_size, offset

def format_vector(embedding: Optional[List[float]]) -> Optional[str]:
    if embedding is None:
        return None
    return "[" + ",".join(str(float(x)) for x in embedding) + "]"

def json_error(message: str, status: int = 400):
    return jsonify({"error": message}), status

# --- API Endpoints ---

@app.route('/health', methods=['GET'])
def health():
    return jsonify({"status": "ok"})

@app.route('/conversations', methods=['GET'])
def get_conversations():
    """
    Retrieves paginated list of conversations.
    Query params:
      page (default 1)
      page_size (default 20)
      include_counts=true|false (default true)
    """
    include_counts = request.args.get("include_counts", "true").lower() == "true"
    conn = get_db_connection()
    if conn is None:
        return json_error("Failed to connect to database", 500)

    page_size, offset = parse_pagination()
    try:
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM conversations;")
        total = cur.fetchone()[0]

        if include_counts:
            cur.execute("""
                SELECT c.id,
                       c.created_at,
                       c.title,
                       (SELECT COUNT(*) FROM chat_messages m WHERE m.conversation_id = c.id) AS message_count
                FROM conversations c
                ORDER BY c.created_at DESC
                LIMIT %s OFFSET %s;
            """, (page_size, offset))
            rows = cur.fetchall()
            conversations = [
                {
                    "id": r[0],
                    "created_at": r[1],
                    "title": r[2],
                    "message_count": r[3]
                } for r in rows
            ]
        else:
            cur.execute("""
                SELECT id, created_at, title
                FROM conversations
                ORDER BY created_at DESC
                LIMIT %s OFFSET %s;
            """, (page_size, offset))
            rows = cur.fetchall()
            conversations = [{"id": r[0], "created_at": r[1], "title": r[2]} for r in rows]

        cur.close()
        conn.close()
        page = (offset // page_size) + 1
        return jsonify({
            "page": page,
            "page_size": page_size,
            "total": total,
            "has_next": offset + page_size < total,
            "conversations": conversations
        })
    except Exception as e:
        app.logger.exception("Error fetching conversations")
        conn.close()
        return json_error(f"Failed to fetch conversations: {e}", 500)

@app.route('/conversations/<int:conv_id>', methods=['GET'])
def get_conversation_details(conv_id):
    """
    Retrieves messages for a conversation (paginated).
    Query params:
      page, page_size
      include_embeddings=true|false
    """
    include_embeddings = request.args.get("include_embeddings", "false").lower() == "true"
    conn = get_db_connection()
    if conn is None:
        return json_error("Failed to connect to database", 500)

    page_size, offset = parse_pagination()
    try:
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM chat_messages WHERE conversation_id = %s;", (conv_id,))
        total = cur.fetchone()[0]
        if total == 0:
            cur.close()
            conn.close()
            return json_error("Conversation not found", 404)

        select_cols = "id, conversation_id, sender, message, model_name, created_at"
        if include_embeddings:
            select_cols += ", embedding"

        cur.execute(
            f"SELECT {select_cols} FROM chat_messages "
            "WHERE conversation_id = %s ORDER BY created_at ASC LIMIT %s OFFSET %s;",
            (conv_id, page_size, offset)
        )
        rows = cur.fetchall()
        cur.close()
        conn.close()

        messages = []
        for r in rows:
            base = {
                "id": r[0],
                "conversation_id": r[1],
                "sender": r[2],
                "message": r[3],
                "model_name": r[4],
                "created_at": r[5]
            }
            if include_embeddings:
                base["embedding"] = list(r[6]) if r[6] is not None else None
            messages.append(base)

        page = (offset // page_size) + 1
        return jsonify({
            "conversation_id": conv_id,
            "page": page,
            "page_size": page_size,
            "total": total,
            "has_next": offset + page_size < total,
            "messages": messages
        })
    except Exception as e:
        app.logger.exception("Error fetching conversation details")
        conn.close()
        return json_error(f"Failed to fetch conversation: {e}", 500)

@app.route('/conversations/<int:conv_id>/export', methods=['GET'])
def export_conversation(conv_id):
    """
    Exports entire conversation (all messages) as a JSON file download.
    """
    conn = get_db_connection()
    if conn is None:
        return json_error("Failed to connect to database", 500)
    try:
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute("SELECT id, created_at, title FROM conversations WHERE id = %s;", (conv_id,))
        conv = cur.fetchone()
        if not conv:
            cur.close()
            conn.close()
            return json_error("Conversation not found", 404)

        cur.execute("""
            SELECT id, conversation_id, sender, message, model_name, created_at
            FROM chat_messages
            WHERE conversation_id = %s
            ORDER BY created_at ASC;
        """, (conv_id,))
        msgs = cur.fetchall()
        cur.close()
        conn.close()
        payload = {
            "conversation": conv,
            "messages": msgs
        }
        return Response(
            json.dumps(payload, default=str),
            mimetype="application/json",
            headers={"Content-Disposition": f"attachment; filename=conversation_{conv_id}.json"}
        )
    except Exception as e:
        app.logger.exception("Export failed")
        conn.close()
        return json_error(f"Failed to export conversation: {e}", 500)

@app.route('/conversations/<int:conv_id>', methods=['PATCH'])
def update_conversation(conv_id):
    """
    Update conversation metadata (currently only title).
    Body JSON:
      title (str, optional)
    """
    data = request.json or {}
    title = data.get("title")
    if title is None or not isinstance(title, str) or not title.strip():
        return json_error("Title is required", 400)

    conn = get_db_connection()
    if conn is None:
        return json_error("Failed to connect to database", 500)
    try:
        cur = conn.cursor()
        cur.execute("UPDATE conversations SET title = %s WHERE id = %s RETURNING id, created_at, title;",
                    (title.strip(), conv_id))
        row = cur.fetchone()
        if not row:
            conn.rollback()
            cur.close()
            conn.close()
            return json_error("Conversation not found", 404)
        conn.commit()
        cur.close()
        conn.close()
        return jsonify({
            "id": row[0],
            "created_at": row[1],
            "title": row[2]
        })
    except Exception as e:
        app.logger.exception("Failed to update conversation")
        conn.rollback()
        conn.close()
        return json_error(f"Failed to update conversation: {e}", 500)


@app.route('/conversations/<int:conv_id>', methods=['DELETE'])
def delete_conversation(conv_id):
    """
    Delete a single conversation and all its messages.
    """
    conn = get_db_connection()
    if conn is None:
        return json_error("Failed to connect to database", 500)
    try:
        cur = conn.cursor()
        # Delete messages first due to FK constraints (if any ON DELETE CASCADE not defined)
        cur.execute("DELETE FROM chat_messages WHERE conversation_id = %s;", (conv_id,))
        cur.execute("DELETE FROM conversations WHERE id = %s RETURNING id;", (conv_id,))
        row = cur.fetchone()
        if not row:
            conn.rollback()
            cur.close()
            conn.close()
            return json_error("Conversation not found", 404)
        conn.commit()
        cur.close()
        conn.close()
        return jsonify({"deleted": True, "conversation_id": conv_id})
    except Exception as e:
        app.logger.exception("Failed to delete conversation")
        conn.rollback()
        conn.close()
        return json_error(f"Failed to delete conversation: {e}", 500)


@app.route('/conversations/bulk_delete', methods=['POST'])
def bulk_delete_conversations():
    """
    Bulk delete conversations and their messages.

    Request JSON:
      {
        "conversation_ids": [1,2,3]
      }

    Response JSON:
      {
        "requested": [1,2,3],
        "deleted": [1,2],
        "not_found": [3],
        "errors": []
      }

    Notes:
      - Ignores non-integer IDs.
      - Performs all deletions in a single transaction for atomicity.
      - If any unexpected error occurs, no deletions are committed.
    """
    data = request.json or {}
    ids = data.get("conversation_ids")
    if not isinstance(ids, list) or not ids:
        return json_error("conversation_ids (non-empty list) is required", 400)

    # Sanitize & unique integer IDs
    try:
        conv_ids = list({int(x) for x in ids})
    except (ValueError, TypeError):
        return json_error("conversation_ids must be integers", 400)

    conn = get_db_connection()
    if conn is None:
        return json_error("Failed to connect to database", 500)

    deleted = []
    not_found = []
    try:
        cur = conn.cursor()
        for cid in conv_ids:
            # Delete messages first (unless ON DELETE CASCADE present)
            cur.execute("DELETE FROM chat_messages WHERE conversation_id = %s;", (cid,))
            cur.execute("DELETE FROM conversations WHERE id = %s RETURNING id;", (cid,))
            row = cur.fetchone()
            if row:
                deleted.append(cid)
            else:
                not_found.append(cid)

        conn.commit()
        cur.close()
        conn.close()
        return jsonify({
            "requested": conv_ids,
            "deleted": deleted,
            "not_found": not_found,
            "errors": []
        })
    except Exception as e:
        app.logger.exception("Bulk delete failed")
        conn.rollback()
        conn.close()
        return json_error(f"Bulk delete error: {e}", 500)


@app.route('/messages', methods=['POST'])
def add_message():
    """
    Adds a new message.
    Body JSON:
      message (str, required)
      sender (str, required) - 'user' or 'ai'
      conversation_id (int, optional) - creates new if omitted
      conversation_title (str, optional) - only used when creating a new conversation
      model_name (str, optional)
      embedding (list[float], optional) - vector embedding
    """
    data = request.json or {}
    user_message = data.get("message")
    conv_id = data.get("conversation_id")
    sender = data.get("sender")
    model_name = data.get("model_name")
    embedding = data.get("embedding")
    conv_title = data.get("conversation_title")

    if not user_message or not sender:
        return json_error("Message and sender are required", 400)

    if embedding is not None:
        if not isinstance(embedding, list) or not all(isinstance(x, (int, float)) for x in embedding):
            return json_error("Embedding must be a list of numbers", 400)

    conn = get_db_connection()
    if conn is None:
        return json_error("Failed to connect to database", 500)

    try:
        cur = conn.cursor()
        if not conv_id:
            if conv_title and isinstance(conv_title, str) and conv_title.strip():
                cur.execute("INSERT INTO conversations (title) VALUES (%s) RETURNING id;", (conv_title.strip(),))
            else:
                cur.execute("INSERT INTO conversations DEFAULT VALUES RETURNING id;")
            conv_id = cur.fetchone()[0]

        vec = format_vector(embedding) if embedding is not None else None

        # Determine column list dynamically based on available fields
        # Assuming schema includes model_name & embedding
        cur.execute(
            """
            INSERT INTO chat_messages (conversation_id, sender, message, model_name, embedding)
            VALUES (%s, %s, %s, %s, %s)
            RETURNING id, created_at;
            """,
            (conv_id, sender, user_message, model_name, vec)
        )
        msg_id, created_at = cur.fetchone()
        conn.commit()
        cur.close()
        conn.close()
        return jsonify({
            "id": msg_id,
            "conversation_id": conv_id,
            "message": user_message,
            "sender": sender,
            "model_name": model_name,
            "created_at": created_at,
            "conversation_title": conv_title
        }), 201
    except Exception as e:
        app.logger.exception("Failed to insert message")
        conn.rollback()
        conn.close()
        return json_error(f"Failed to add message: {e}", 500)

@app.route('/conversations/<int:conv_id>/context', methods=['GET'])
def get_conversation_context(conv_id):
    """
    Get conversation context for n8n/AI agent memory.
    Returns messages in chronological order formatted for AI consumption.
    Query params:
      limit (int, default 20) - maximum messages to return
      include_system (bool, default false) - include system messages
    """
    limit = int(request.args.get("limit", 20))
    include_system = request.args.get("include_system", "false").lower() == "true"
    limit = max(1, min(limit, 100))

    conn = get_db_connection()
    if conn is None:
        return json_error("Failed to connect to database", 500)

    try:
        cur = conn.cursor()

        # Check if conversation exists
        cur.execute("SELECT COUNT(*) FROM conversations WHERE id = %s;", (conv_id,))
        if cur.fetchone()[0] == 0:
            cur.close()
            conn.close()
            return json_error("Conversation not found", 404)

        # Get recent messages in chronological order
        base_sql = """
            SELECT sender, message, created_at
            FROM chat_messages
            WHERE conversation_id = %s
        """
        params = [conv_id]

        if not include_system:
            base_sql += " AND sender IN ('user', 'ai')"

        base_sql += " ORDER BY created_at ASC LIMIT %s;"
        params.append(limit)

        cur.execute(base_sql, params)
        rows = cur.fetchall()
        cur.close()
        conn.close()

        # Format for AI consumption
        context_messages = []
        for row in rows:
            sender, message, created_at = row
            # Map sender to standard AI role format
            role = "user" if sender == "user" else "assistant"
            context_messages.append({
                "role": role,
                "content": message,
                "timestamp": created_at.isoformat() if created_at else None
            })

        return jsonify({
            "conversation_id": conv_id,
            "context": context_messages,
            "message_count": len(context_messages),
            "truncated": len(context_messages) == limit
        })

    except Exception as e:
        app.logger.exception("Error fetching conversation context")
        conn.close()
        return json_error(f"Failed to fetch context: {e}", 500)

@app.route('/similarity_search', methods=['POST'])
def similarity_search():
    """
    Performs a similarity search using pgvector.
    Body JSON:
      query_embedding (list[float], required)
      top_k (int, default 10)
      conversation_id (optional) - restrict to a single conversation
    Returns messages ordered by distance ascending (converted to similarity score).
    """
    data = request.json or {}
    query_embedding = data.get("query_embedding")
    top_k = int(data.get("top_k", 10))
    conv_id = data.get("conversation_id")

    if not isinstance(query_embedding, list) or not all(isinstance(x, (int, float)) for x in query_embedding):
        return json_error("query_embedding must be a list of numbers", 400)
    top_k = max(1, min(top_k, 100))

    vec = format_vector(query_embedding)
    conn = get_db_connection()
    if conn is None:
        return json_error("Failed to connect to database", 500)
    try:
        cur = conn.cursor(cursor_factory=RealDictCursor)
        base_sql = """
            SELECT id,
                   conversation_id,
                   sender,
                   message,
                   model_name,
                   created_at,
                   1 - (embedding <=> %s::vector) AS similarity
            FROM chat_messages
            WHERE embedding IS NOT NULL
        """
        params = [vec]
        if conv_id:
            base_sql += " AND conversation_id = %s"
            params.append(conv_id)
        base_sql += " ORDER BY embedding <=> %s::vector ASC LIMIT %s;"
        params.extend([vec, top_k])
        cur.execute(base_sql, params)
        rows = cur.fetchall()
        cur.close()
        conn.close()
        return jsonify({
            "results": rows,
            "count": len(rows)
        })
    except Exception as e:
        app.logger.exception("Similarity search failed")
        conn.close()
        return json_error(f"Similarity search error: {e}", 500)

# Global error handlers
@app.errorhandler(404)
def not_found(_):
    return json_error("Not found", 404)

@app.errorhandler(500)
def internal_error(_):
    return json_error("Internal server error", 500)

# Note: The Flutter client should make this backend URL configurable in its Settings
# so it can point to this service for history operations.
