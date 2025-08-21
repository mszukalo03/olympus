# main.py
from fastapi import FastAPI, HTTPException, Depends, UploadFile, File
from pydantic import BaseModel
from sqlalchemy import create_engine, text, Column, Integer, String, inspect
from sqlalchemy.orm import sessionmaker, declarative_base
from sqlalchemy.exc import ProgrammingError
from pgvector.sqlalchemy import Vector
from sentence_transformers import SentenceTransformer
import uvicorn
import os

# --- Configuration ---
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://mszukalo:terriers@10.0.0.150:5338/ragdb")
EMBEDDING_MODEL = 'all-MiniLM-L6-v2'

# --- Database Setup ---
engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

# --- Sentence Transformer Model ---
# The joblib warning "[Errno 13] Permission denied" is not a fatal error.
# It means sentence-transformers will run in serial mode, which might be slightly slower
# but is fine for this application.
model = SentenceTransformer(EMBEDDING_MODEL)

# --- FastAPI App ---
app = FastAPI(
    title="RAG Backend API",
    description="An API for managing and querying a RAG database with PostgreSQL and pgvector.",
    version="1.0.0"
)

# --- Utility Helpers ---
def to_vector_literal(arr):
    "Format a Python list[float] into pgvector literal string."
    if not isinstance(arr, (list, tuple)):
        raise ValueError("Embedding must be list or tuple")
    return "[" + ",".join(str(float(x)) for x in arr) + "]"

# --- Pydantic Models ---
class Collection(BaseModel):
    name: str

class Document(BaseModel):
    collection_name: str
    content: str

class DocumentUpdate(BaseModel):
    content: str

class Query(BaseModel):
    collection_name: str
    query_text: str
    top_k: int = 5

# --- Database Dependency ---
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

# --- API Endpoints ---

@app.post("/collections", status_code=201)
def create_collection(collection: Collection, db: SessionLocal = Depends(get_db)):
    """
    Creates a new collection (table) in the database to store documents and their embeddings.
    """
    table_name = collection.name.lower().replace(" ", "_")

    # Prevent SQLAlchemy MetaData duplicate definition error if the class/table
    # was already registered earlier in this process (even if the DB table exists).
    if table_name in Base.metadata.tables:
        raise HTTPException(status_code=400, detail=f"Collection '{table_name}' already exists.")

    # Check if table already exists in the physical database
    inspector = inspect(engine)
    if inspector.has_table(table_name):
        raise HTTPException(status_code=400, detail=f"Collection '{table_name}' already exists.")

    try:
        # Create a new table for the collection
        new_collection_table = type(
            table_name,
            (Base,),
            {
                '__tablename__': table_name,
                'id': Column(Integer, primary_key=True, index=True),
                'content': Column(String, nullable=False),
                'embedding': Column(Vector(384)) # Dimension from all-MiniLM-L6-v2
            }
        )
        Base.metadata.create_all(engine, tables=[new_collection_table.__table__])
        return {"message": f"Collection '{table_name}' created successfully."}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/collections")
def list_collections():
    """
    Lists all existing collection (table) names.
    """
    inspector = inspect(engine)
    tables = inspector.get_table_names()
    return {"collections": tables}

@app.get("/collections/{collection_name}/documents")
def list_documents(collection_name: str, limit: int = 50, offset: int = 0):
    """
    List documents in a collection with pagination.
    """
    table_name = collection_name.lower().replace(" ", "_")
    inspector = inspect(engine)
    if not inspector.has_table(table_name):
        raise HTTPException(status_code=404, detail=f"Collection '{table_name}' not found.")

    try:
        with engine.connect() as connection:
            result = connection.execute(
                text(f'SELECT id, content FROM "{table_name}" ORDER BY id DESC LIMIT :limit OFFSET :offset'),
                {"limit": limit, "offset": offset}
            )
            docs = [{"id": row[0], "content": row[1]} for row in result]
        return {"documents": docs, "count": len(docs), "limit": limit, "offset": offset}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/collections/{collection_name}/documents/{doc_id}")
def get_document(collection_name: str, doc_id: int):
    """
    Retrieve a single document by id.
    """
    table_name = collection_name.lower().replace(" ", "_")
    inspector = inspect(engine)
    if not inspector.has_table(table_name):
        raise HTTPException(status_code=404, detail=f"Collection '{table_name}' not found.")
    try:
        with engine.connect() as connection:
            result = connection.execute(
                text(f'SELECT id, content FROM "{table_name}" WHERE id = :id'),
                {"id": doc_id}
            ).fetchone()
        if not result:
            raise HTTPException(status_code=404, detail="Document not found.")
        return {"id": result[0], "content": result[1]}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.put("/collections/{collection_name}/documents/{doc_id}")
def update_document(collection_name: str, doc_id: int, doc: DocumentUpdate):
    """
    Update a document's content (and regenerate its embedding).
    """
    table_name = collection_name.lower().replace(" ", "_")
    inspector = inspect(engine)
    if not inspector.has_table(table_name):
        raise HTTPException(status_code=404, detail=f"Collection '{table_name}' not found.")
    try:
        embedding = model.encode(doc.content).tolist()
        embedding_literal = to_vector_literal(embedding)
        with engine.connect() as connection:
            result = connection.execute(
                text(f'UPDATE "{table_name}" SET content = :content, embedding = :embedding WHERE id = :id RETURNING id'),
                {"content": doc.content, "embedding": embedding_literal, "id": doc_id}
            ).fetchone()
            connection.commit()
        if not result:
            raise HTTPException(status_code=404, detail="Document not found.")
        return {"message": "Document updated successfully.", "id": result[0]}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.delete("/collections/{collection_name}/documents/{doc_id}")
def delete_document(collection_name: str, doc_id: int):
    """
    Delete a document by id.
    """
    table_name = collection_name.lower().replace(" ", "_")
    inspector = inspect(engine)
    if not inspector.has_table(table_name):
        raise HTTPException(status_code=404, detail=f"Collection '{table_name}' not found.")
    try:
        with engine.connect() as connection:
            result = connection.execute(
                text(f'DELETE FROM "{table_name}" WHERE id = :id RETURNING id'),
                {"id": doc_id}
            ).fetchone()
            connection.commit()
        if not result:
            raise HTTPException(status_code=404, detail="Document not found.")
        return {"message": "Document deleted successfully.", "id": result[0]}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.delete("/collections/{collection_name}")
def delete_collection(collection_name: str, db: SessionLocal = Depends(get_db)):
    """
    Deletes a collection (table) from the database.
    """
    table_name = collection_name.lower().replace(" ", "_")
    inspector = inspect(engine)
    if not inspector.has_table(table_name):
        raise HTTPException(status_code=404, detail=f"Collection '{table_name}' not found.")

    try:
        # Drop the table
        with engine.connect() as connection:
            connection.execute(text(f'DROP TABLE "{table_name}"'))
            connection.commit()
        return {"message": f"Collection '{table_name}' deleted successfully."}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/documents", status_code=201)
def add_document(doc: Document, db: SessionLocal = Depends(get_db)):
    """
    Adds a new document to a specified collection and stores its vector embedding.
    """
    table_name = doc.collection_name.lower().replace(" ", "_")
    inspector = inspect(engine)
    if not inspector.has_table(table_name):
        raise HTTPException(status_code=404, detail=f"Collection '{table_name}' not found.")

    try:
        # Generate embedding
        embedding = model.encode(doc.content).tolist()
        embedding_literal = to_vector_literal(embedding)

        # Insert document and embedding into the table
        with engine.connect() as connection:
            result = connection.execute(
                text(f'INSERT INTO "{table_name}" (content, embedding) VALUES (:content, :embedding) RETURNING id'),
                {"content": doc.content, "embedding": embedding_literal}
            )
            new_id = result.scalar()
            connection.commit()
        return {"message": "Document added successfully.", "id": new_id}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# --- File Ingestion Endpoint --------------------------------------------------
@app.post("/collections/{collection_name}/ingest_file")
def ingest_file(collection_name: str,
                file: UploadFile = File(...),
                chunk_size: int = 800,
                overlap: int = 100):
    """
    Ingest a text or PDF file into the specified collection.

    - Supports .txt and .pdf
    - Splits file text into overlapping chunks (default 800 chars, 100 overlap)
    - Generates an embedding per chunk and inserts each as a separate row
    - Returns inserted row IDs and counts

    Parameters:
      chunk_size: maximum characters per chunk
      overlap: number of characters of overlap between consecutive chunks
    """
    table_name = collection_name.lower().replace(" ", "_")
    inspector = inspect(engine)
    if not inspector.has_table(table_name):
        raise HTTPException(status_code=404, detail=f"Collection '{table_name}' not found.")

    filename = file.filename or "uploaded"
    ext = filename.lower().rsplit(".", 1)[-1] if "." in filename else ""
    try:
        if ext == "txt":
            raw_bytes = file.file.read()
            text_data = raw_bytes.decode("utf-8", errors="ignore")
        elif ext == "pdf":
            try:
                from pypdf import PdfReader  # type: ignore
            except Exception:
                raise HTTPException(
                    status_code=500,
                    detail="PDF ingestion requires 'pypdf'. Install with: pip install pypdf"
                )
            import io
            reader = PdfReader(io.BytesIO(file.file.read()))
            pages = []
            for p in reader.pages:
                try:
                    pages.append(p.extract_text() or "")
                except Exception:
                    pages.append("")
            text_data = "\n".join(pages)
        else:
            raise HTTPException(status_code=400, detail="Only .txt and .pdf files are supported.")
    finally:
        # Reset pointer (not strictly necessary after read, but keeps consistency)
        try:
            file.file.seek(0)
        except Exception:
            pass

    cleaned = text_data.replace("\r", " ").strip()
    if not cleaned:
        raise HTTPException(status_code=400, detail="File appears to be empty or unreadable.")

    # Chunk the text
    if chunk_size <= 0:
        chunk_size = 800
    if overlap < 0:
        overlap = 0
    if overlap >= chunk_size:
        overlap = max(0, chunk_size // 4)

    chunks = []
    start = 0
    length = len(cleaned)
    while start < length:
        end = min(length, start + chunk_size)
        chunk = cleaned[start:end].strip()
        if chunk:
            chunks.append(chunk)
        if end >= length:
            break
        start = end - overlap

    if not chunks:
        raise HTTPException(status_code=400, detail="No valid chunks produced from file content.")

    inserted_ids = []
    with engine.connect() as connection:
        for ch in chunks:
            emb = model.encode(ch).tolist()
            emb_literal = to_vector_literal(emb)
            res = connection.execute(
                text(f'INSERT INTO "{table_name}" (content, embedding) VALUES (:c, :e) RETURNING id'),
                {"c": ch, "e": emb_literal}
            )
            new_id = res.scalar()
            if new_id is not None:
                inserted_ids.append(new_id)
        connection.commit()

    return {
        "collection": table_name,
        "file": filename,
        "chunks": len(chunks),
        "inserted": len(inserted_ids),
        "ids": inserted_ids
    }

@app.post("/query")
def query_collection(query: Query, db: SessionLocal = Depends(get_db)):
    """
    Queries a collection to find the most similar documents to the query text.
    (Returns id, content, similarity)
    """
    table_name = query.collection_name.lower().replace(" ", "_")
    inspector = inspect(engine)
    if not inspector.has_table(table_name):
        raise HTTPException(status_code=404, detail=f"Collection '{table_name}' not found.")

    try:
        # Generate embedding for the query
        query_embedding = model.encode(query.query_text).tolist()
        query_embedding_literal = to_vector_literal(query_embedding)

        # Perform similarity search
        with engine.connect() as connection:
            result = connection.execute(
                text(f"SELECT id, content, 1 - (embedding <=> :query_embedding) AS similarity FROM \"{table_name}\" ORDER BY similarity DESC LIMIT :limit"),
                {"query_embedding": query_embedding_literal, "limit": query.top_k}
            )
            results = [{"id": row[0], "content": row[1], "similarity": row[2]} for row in result]

        return {"results": results}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    # Before running the app, make sure to enable the pgvector extension in your PostgreSQL database:
    # CREATE EXTENSION IF NOT EXISTS vector;
    uvicorn.run(app, host="0.0.0.0", port=8890)
