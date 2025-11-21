# 🎨 "New" Tool for GIFs 
https://github.com/pstaylor-patrick/utility-scripts/blob/master/gif.sh

Got GIFs? Sure, you could search GIPHY. But what about making your own?

I wrote a bash script that takes MP4 video and converts to GIF with configurable low, mid, or high resolution.

For context, I recently stopped paying for the Adobe suite and prefer to avoid online freeware like https://www.adobe.com/express/feature/video/convert/video-to-gif

So I wrote this (with lots of help from AI) to simplify and accelerate the viability of GIFs as a communication medium. Especially when trying to visualize a complex interaction or get a point across that benefits from illustrations.

Tangent, but I cut my MP4s in Olive, a free, open source non-linear video editor. I've found it mirrors Adobe Premiere Pro quite well, especially considering it costs $0 per month. Very quick to go from a QuickTime screen recording to an Olive sequence to a GIF just like that. 🫰

For example, I took a 41.7 MB QuickTime MOV screen recording

And used Olive to cut it to a 812 KB MP4 video

And then used the GIF script to encode it into these three GIFs:

| Resolution | Size  | Preview |
|------------|-------|---------|
| Low        | 97 KB | <img src="./gif/12c8488%20low.gif" alt="Low Resolution GIF" width="300"/> |
| Mid        | 266 KB| <img src="./gif/12c8488%20mid.gif" alt="Mid Resolution GIF" width="300"/> |
| High       | 445 KB| <img src="./gif/12c8488%20high.gif" alt="High Resolution GIF" width="300"/> |
