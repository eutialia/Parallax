# Signed out and asked for my password again, but the server is fine

My Jellyfin server sits behind a reverse proxy that makes me log in with my company single sign-on before I can reach it. Jellyfin is signed in on my phone and works normally.

Now and then, when my proxy login lapses, Parallax shows the server as signed out and asks for my Jellyfin password again. The server itself is fine: nothing changed on it, and my account and password are the same. Entering the password in the app doesn't help while the proxy still wants its own login, and by then Parallax has already forgotten my Jellyfin sign-in. Once the proxy lets me through again I still have to set everything up from scratch.

I expected Parallax to say it couldn't reach the server for a moment, keep me signed in, and have my Home screen back as soon as the proxy let me through.
