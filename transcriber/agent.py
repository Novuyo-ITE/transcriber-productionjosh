from typing import Optional
import re
import os
import logging
from dotenv import load_dotenv
from langchain_google_genai import ChatGoogleGenerativeAI
from langchain_core.messages import SystemMessage, HumanMessage

# Load environment variables from .env
load_dotenv()

logging.basicConfig(level=logging.DEBUG, format='[%(levelname)s] %(asctime)s %(module)s: %(message)s')

def get_best_model():
    """Returns the Gemini model to use for transcription editing tasks."""
    return os.getenv('GEMINI_MODEL', 'gemini-2.5-flash')

EDIT_KEYWORDS = (
    "rewrite", "edit", "format", "fix", "correct", "clean", "refine",
    "translate", "punctuation", "spacing", "dialogue", "conversational",
    "speaker", "arrange", "rearrange", "modify", "improve"
)

QA_KEYWORDS = ("summarize", "summary", "explain", "question", "answer", "what", "why", "how")

def get_llm(num_predict: int = 8192) -> ChatGoogleGenerativeAI:
    """Return a fresh ChatGoogleGenerativeAI instance using Gemini.

    Reads GEMINI_API_KEY (or GOOGLE_API_KEY) from environment variables loaded from .env.
    """
    model = get_best_model()
    api_key = os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY")
    logging.debug(
        "Creating ChatGoogleGenerativeAI instance (model=%s)",
        model,
    )
    kwargs = {
        "model": model,
        "temperature": 0.0,
        "max_output_tokens": 8192,
    }
    if api_key:
        kwargs["google_api_key"] = api_key

    return ChatGoogleGenerativeAI(**kwargs)

def invoke_llm_messages(messages, num_predict: int = 8192):
    """Invoke Gemini model via LangChain."""
    return get_llm(num_predict=num_predict).invoke(messages)

def detect_intent(prompt: str) -> str:
    """Classify whether the user wants replacement transcript text or an answer."""
    prompt_lower = (prompt or "").lower()
    if any(keyword in prompt_lower for keyword in QA_KEYWORDS):
        return "QA"
    return "edit"

def run_co_pilot_agent(prompt: str, selected_text: Optional[str], full_transcription: str) -> dict:
    """Invokes Gemini using LangChain for speaker attribution, editing, summarization, and Q&A"""
    intent = detect_intent(prompt)
    context = selected_text if (selected_text and selected_text.strip()) else full_transcription

    if intent == "edit":
        system_instructions = (
            "You are an expert audio dialogue transcriber and speaker attribution specialist.\n"
            "Your task is to identify different speakers and attribute what was said into distinct conversational dialogue turns with timestamps.\n\n"
            "STRICT RULES:\n"
            "1. FORMAT: Format every dialogue turn as:\n"
            "   [MM:SS] Speaker X: <exact transcribed text>\n"
            "2. VERBATIM ACCURACY: Keep all original transcribed words 100% intact. Do NOT change, replace, rewrite, omit, or summarize any words.\n"
            "3. SPEAKER IDENTIFICATION: Identify conversational turn-taking and tag distinct speakers as Speaker 1, Speaker 2, Speaker 3, etc. (or names if explicitly stated).\n"
            "4. MERGING: Merge consecutive sentences from the same speaker into a continuous natural paragraph.\n"
            "5. OUTPUT: Output ONLY the formatted dialogue portions. No explanations, no filler text, no conversational chatter."
        )
    else:
        system_instructions = (
            "You are an expert AI Intelligence Assistant specializing in audio transcription analysis, summarization, and question answering.\n\n"
            "YOUR CORE CAPABILITIES:\n"
            "1. SUMMARIZATION & KEY POINTS: When asked to summarize or provide key takeaways, produce crisp, well-structured executive summaries, bullet points, and action items.\n"
            "2. QUESTION ANSWERING (Q&A): Accurately answer any questions about who said what, topics discussed, decisions made, facts, or context from the provided transcript.\n"
            "3. INSIGHTS & TRANSLATION: Explain terminology, analyze sentiment/tone, or translate selected portions if requested.\n\n"
            "GUIDELINES:\n"
            "- Base your answers strictly on the provided transcript context.\n"
            "- Be concise, direct, helpful, and beautifully formatted in markdown."
        )
    
    user_prompt = (
        f"<TRANSCRIPTION_CONTEXT>\n{context}\n</TRANSCRIPTION_CONTEXT>\n\n"
        f"<USER_REQUEST>\n{prompt}\n</USER_REQUEST>"
    )

    try:
        # Invoke Gemini model via LangChain ChatGoogleGenerativeAI
        logging.debug('Invoking LLM with system and user prompts')
        response = invoke_llm_messages([
            SystemMessage(content=system_instructions),
            HumanMessage(content=user_prompt)
        ])
        logging.debug(f'LLM raw response: {response}')
        output = response.content.strip()
        
        # 1. Clean up any thinking/reasoning tags
        output = re.sub(r'<think>.*?</think>', '', output, flags=re.DOTALL).strip()
        
        # 2. Strip markdown code block ticks if LLM wrapped full response accidentally
        if output.startswith("```markdown"):
            output = output[11:].strip()
            if output.endswith("```"):
                output = output[:-3].strip()
        elif output.startswith("```"):
            lines = output.split("\n")
            if lines[0].startswith("```"):
                lines = lines[1:]
            if lines and lines[-1].strip() == "```":
                lines = lines[:-1]
            output = "\n".join(lines).strip()
                
    except Exception as e:
        logging.exception('Error during LLM invocation')
        output = f"AI Assistant error: {str(e)}"
    return {
        'intent': intent,
        'output': output
    }
