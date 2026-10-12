import uuid
from django.db import models
from django.contrib.auth.models import User

class Transcription(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='transcriptions', null=True, blank=True)
    original_name = models.CharField(max_length=255)
    audio_path = models.CharField(max_length=500)
    language = models.CharField(max_length=50)
    transcription = models.TextField(blank=True, null=True)
    formatted = models.TextField(blank=True, null=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        username = self.user.username if self.user else "Guest"
        return f"{self.original_name} [{username}] ({self.created_at.strftime('%Y-%m-%d %H:%M')})"
