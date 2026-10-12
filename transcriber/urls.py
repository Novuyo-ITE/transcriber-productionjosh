from django.urls import path
from . import views

app_name = 'transcriber'

urlpatterns = [
    path('', views.landing_view, name='landing'),
    path('app/', views.index_view, name='app'),
    path('stream/', views.stream_page_view, name='stream_page'),
    path('workspace/', views.index_view, name='workspace'),
    path('api/history/', views.get_history_view, name='get_history'),
    path('api/transcription/<str:tid>/', views.get_transcription_view, name='get_transcription'),
    path('api/transcribe/', views.transcribe_view, name='transcribe'),
    path('api/update/<str:tid>/', views.update_transcription_view, name='update_transcription'),
    path('api/chat/', views.chat_co_pilot_view, name='chat_co_pilot'),
    path('download/text/<str:tid>/', views.download_text_view, name='download_text'),
    path('download/raw/<str:tid>/', views.download_raw_text_view, name='download_raw_text'),
    path('download/edited/<str:tid>/', views.download_edited_text_view, name='download_edited_text'),
    path('download/audio/<str:tid>/', views.download_audio_view, name='download_audio'),
    path('api/diarize/<str:tid>/', views.diarize_transcription_view, name='diarize_transcription'),
    path('api/stream_audio/<str:tid>/', views.stream_audio_view, name='stream_audio'),
    path('api/delete/<str:tid>/', views.delete_transcription_view, name='delete_transcription'),
    path('api/rename/<str:tid>/', views.rename_transcription_view, name='rename_transcription'),
    path('api/progress/<str:job_id>/', views.get_progress_view, name='get_progress'),
    path('api/stream_warmup/', views.stream_warmup_view, name='stream_warmup'),
    path('api/stream_transcribe_chunk/', views.stream_transcribe_chunk_view, name='stream_transcribe_chunk'),
    path('api/save_stream_session/', views.save_stream_session_view, name='save_stream_session'),
    path('api/login/', views.login_view, name='login'),
    path('api/register/', views.register_view, name='register'),
    path('api/logout/', views.logout_view, name='logout'),
]
