import os
import sqlite3
import django
from datetime import datetime

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'transcriber_project.settings')
django.setup()

from transcriber.models import Transcription

old_db_path = os.path.join("database", "transcriptions.db")
if os.path.exists(old_db_path):
    print("Found old transcriptions database. Migrating records...")
    conn = sqlite3.connect(old_db_path)
    c = conn.cursor()
    try:
        # Get table info to see if columns exist
        c.execute("PRAGMA table_info(transcriptions)")
        columns = [col[1] for col in c.fetchall()]
        
        select_cols = ["id", "original_name", "audio_path", "language", "transcription"]
        if "formatted" in columns:
            select_cols.append("formatted")
        else:
            select_cols.append("NULL as formatted")
            
        if "created_at" in columns:
            select_cols.append("created_at")
        else:
            select_cols.append("NULL as created_at")

        query = f"SELECT {', '.join(select_cols)} FROM transcriptions"
        c.execute(query)
        rows = c.fetchall()
        count = 0
        for row in rows:
            tid, original_name, audio_path, language, transcription, formatted, created_at_str = row
            
            # Check if record already exists in new Django database
            if not Transcription.objects.filter(id=tid).exists():
                t = Transcription(
                    id=tid,
                    original_name=original_name,
                    audio_path=audio_path,
                    language=language,
                    transcription=transcription,
                    formatted=formatted
                )
                # If we have created_at timestamp from the old DB, preserve it
                if created_at_str:
                    try:
                        # Attempt to parse common SQLite datetime formats
                        if " " in created_at_str:
                            t.created_at = datetime.strptime(created_at_str.split(".")[0], "%Y-%m-%d %H:%M:%S")
                        else:
                            t.created_at = datetime.strptime(created_at_str.split(".")[0], "%Y-%m-%d")
                    except Exception as e:
                        print(f"Could not parse timestamp '{created_at_str}': {e}")
                t.save()
                count += 1
        print(f"Successfully migrated {count} records!")
    except Exception as e:
        print(f"Error during migration: {e}")
        import traceback
        traceback.print_exc()
    finally:
        conn.close()
else:
    print("No old database found at database/transcriptions.db")
