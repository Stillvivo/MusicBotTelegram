import logging
import os
import tempfile
import json
import yt_dlp

from pydub import AudioSegment
from shazamio import Shazam
from telegram import Update, ReplyKeyboardMarkup, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, MessageHandler, ContextTypes, filters

logging.basicConfig(format='%(asctime)s - %(name)s - %(levelname)s - %(message)s', level=logging.INFO)

logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("telegram").setLevel(logging.WARNING)
logging.getLogger("telegram.ext").setLevel(logging.WARNING)

TOKEN = os.environ.get("BOT_TOKEN")
ADMIN_ID = 441170856
USERS_FILE = "users_list.json"
if not TOKEN:
    raise RuntimeError("BOT_TOKEN is not set. Set it as an environment variable")



def save_user_data(user):
    try:
        users = {}
        if os.path.exists(USERS_FILE):
            with open(USERS_FILE, "r",encoding="utf-8") as f:
                users = json.load(f)

        users[str(user.id)] = {
            "username": user.username or "N/A",
            "name": user.full_name or "Unknown"
        }

        with open(USERS_FILE, "w",encoding="utf-8")as f:
            json.dump(users,f,ensure_ascii=False,indent=4)
    except Exception as e:
        logging.error(f"Save User Error: {e}")


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    save_user_data(update.effective_user)

    keyboard = [
        ["پشتیبانی ربات (:"],
        ["بازگشت"],
        ["درباره ربات!"],
    ]
    reply_markup = ReplyKeyboardMarkup(keyboard, resize_keyboard=True, one_time_keyboard=False)

    await update.message.reply_text(
        "سلام خوش آمدید.\n"
        "لطفا برامون آهنگ را به صورت ویس یا فایل صوتی بفرست تا اسم آهنگ و خواننده آهنگ را براتون بفرستیم.\n"
        "برای ارتباط با ما روی <پشتیبانی ربات (: > بزن.",
        reply_markup=reply_markup
    )


async def list_users(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id  != ADMIN_ID:
        return

    if not os.path.exists(USERS_FILE):
        await update.message.reply_text("هنوز کسی ربات را استارت نکرده.")
        return
    try:
        with open(USERS_FILE, "r", encoding="utf-8") as f:
           users = json.load(f)
    except json.JSONDecodeError:
        await update.message.reply_text("فایل کاربران خراب است.")
        return

    text = f"list of users 👥 ({len(users)} person): \n\n"

    for uid, info in users.items():
        text += f"👥{info['name']} | @{info['username']} | {uid}\n"

    await update.message.reply_text(text)


async def support(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "برای پشتیبانی به این آیدی پیام بدهید.\n"
        "@aIirezalt"
    )


async def recognize_with_retry(file_path: str):
    shazam = Shazam()

    try:
        audio = AudioSegment.from_file(file_path)
        audio = audio.normalize().set_channels(1)

        check_point = [0, 20, 40]

        for start_sec in check_point:
            start_ms = start_sec * 1000

            if len(audio) < start_ms:
              continue

            chunk = audio[start_ms: start_ms + 10000]

            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp_chunk:
               chunk.export(tmp_chunk.name, format="wav")
               temp_path = tmp_chunk.name

            try:
               result = await shazam.recognize(temp_path)
            finally:
               if os.path.exists(temp_path):
                   os.unlink(temp_path)

            if result.get("track"):
              track = result["track"]
              return {
                "title": track.get("title"),
                "artist": track.get("subtitle"),
                "image": track.get("images", {}).get("coverart")
              }
    except Exception as e:
         logging.exception(f"Audio processing error: {e}")
    return None



async def handle_audio(update: Update, context: ContextTypes.DEFAULT_TYPE):
    save_user_data(update.effective_user)

    message = update.message

    if not message:
        return
    await message.reply_text("🔍 در حال آنالیز دقیق آهنگ (ممکن است کمی طول بکشد)...")

    try:
        telegram_file = None
        ext = ".mp3"
        if message.voice:
            telegram_file = await context.bot.get_file(message.voice.file_id)
            ext = ".ogg"
        elif message.audio:
            telegram_file = await context.bot.get_file(message.audio.file_id)
            ext = ".mp3"
        else:
            await message.reply_text("لطفا ویس یا فایل صوتی بفرست.")
            return

        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = os.path.join(tmpdir, f"original_audio{ext}")
            await telegram_file.download_to_drive(file_path)

            data = await recognize_with_retry(file_path)

            if data:
                caption = f"🎵 *نام آهنگ:* {data['title']}\n🎤 *خواننده:* {data['artist']}"
                keyboard = [
                    [InlineKeyboardButton("download music⬇️", callback_data=f"download{data['title']} | {data['artist']}")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)

                if data.get("image"):
                    await message.reply_photo(photo=data["image"], caption=caption, parse_mode="Markdown", reply_markup=reply_markup)
                else:
                    await message.reply_text(caption,parse_mode="Markdown", reply_markup=reply_markup)
            else:
                await message.reply_text("در حال آنالیزدقیق آهنگ...(ممکن است کمی طول بکشد)")
    except Exception as e:
        logging.exception(f"Error in handle_audio: {e}")
        await message.reply_text("خطایی در پردازش آهنگ رخ داد.")


async def about_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    text = (
        "🎵 این بات برای تشخیص آهنگ از روی فایل صوتی ساخته شده است.\n"
        "👨‍💻 سازنده: alireza lotfi\n"
        "📩 آیدی:@aIirezalt"
    )
    await update.message.reply_text(text)


async def back(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await start(update, context)

async def download_song(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()

    title, artist = query.data.replace("download", "").split("|")

    search = f"{title.strip()} {artist.strip()} audio"

    await query.message.reply_text("در حال دانلود آهنگ...")

    os.makedirs("downloads", exist_ok=True)

    ydl_opts = {
        'format': 'bestaudio/best',
        'noplaylist': True,
        'outtmpl': 'downloads/%(title)s.%(ext)s',
        'quiet': True,
        'extractaudio': True,
        'audioformat': 'mp3',
        'postprocessors': [{
            'key': 'FFmpegExtractAudio',
            'preferredcodec': 'mp3',
            'preferredquality': '192',
        }],
        'extractor_args': {
            'youtube': {
                'player_client': ["android"]
            }
        }
    }

    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([f"ytsearch1:{search}"])

        for file in os.listdir("downloads"):
            if file.endswith(".mp3"):
                file_path = os.path.join("downloads", file)

                await query.message.reply_audio(audio=open(file_path, "rb"),title=title.strip(),performer=artist.strip())
                os.remove(file_path)
                break
    except Exception as e:
        logging.exception(f"Download error: {e}")
        await query.message.reply_text("دانلود آهنگ با مشکل مواجه شد.")


def main():
    app = Application.builder().token(TOKEN).build() # for build robot

    from telegram.ext import CallbackQueryHandler
    app.add_handler(CallbackQueryHandler(download_song, pattern="^download"))

    app.add_handler(CommandHandler("about", about_command))
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("users", list_users))

    app.add_handler(MessageHandler(filters.Regex(r"^درباره ربات!$"), about_command))
    app.add_handler(MessageHandler(filters.Regex(r"^پشتیبانی ربات \(:$"), support))
    app.add_handler(MessageHandler(filters.Regex(r"^بازگشت$"), back))

    app.add_handler(MessageHandler(filters.VOICE | filters.AUDIO, handle_audio))

    print("Bot is running...")
    app.run_polling()


if __name__ == "__main__":
    main()
