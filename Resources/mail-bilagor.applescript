-- Sparar bilagor fran mejl till eller fran en adress.
--
-- Anropas som: osascript mail-bilagor.applescript <adress> <malmapp> <max per lada>
--
-- Gransen galler per lada. Med en gemensam raknare fyllde inkorgens bilder
-- kvoten innan skickat-ladan nadddes, och det man sjalv skickat - fakturor,
-- offerter - kom aldrig med.
-- Svarar med en rad per sparad bilaga, falten atskilda av ASCII 31:
--   amne | filnamn | sokvag | storlek
--
-- AppleScript-identifierare maste vara ASCII, darav stavningen har.

on run argv
	set adress to item 1 of argv
	set malmapp to item 2 of argv
	set grans to (item 3 of argv) as integer
	set d to (ASCII character 31)
	set ut to ""

	tell application "Mail"
		repeat with konto in accounts
			repeat with ladnamn in {"INBOX", "Sent Messages", "Sent", "Skickat"}
				-- Egen raknare per lada, sa att inkorgen inte tranger undan
				-- det man sjalv har skickat.
				set raknare to 0
				try
					set lada to mailbox (ladnamn as string) of konto
					if (ladnamn as string) is "INBOX" then
						set traffar to (every message of lada whose sender contains adress)
					else
						set traffar to (every message of lada whose (address of every to recipient) contains adress)
					end if
					repeat with m in traffar
						if raknare >= grans then exit repeat
						try
							repeat with b in (every mail attachment of m)
								if raknare >= grans then exit repeat
								try
									-- Namnet kommer fran avsandaren. Ett snedstreck
									-- i det hade pekat ut ur mappen.
									set namn to my rensaNamn(name of b)
									set stl to file size of b
									-- Stora filer hoppas over: de ar sallan text.
									-- Signaturbilder och kalenderfiler sorteras
									-- bort har och inte forst i Swift, annars
									-- raknas de mot kvoten.
									if stl < 26214400 and my varAttSpara(namn) then
										set malfil to malmapp & "/" & namn
										save b in POSIX file malfil
										set raknare to raknare + 1
										set ut to ut & (subject of m) & d & namn & d & malfil & d & (stl as string) & linefeed
									end if
								end try
							end repeat
						end try
					end repeat
				end try
			end repeat
		end repeat
	end tell
	return ut
end run

-- Samma bedomning som i Swift, men gjord har sa att skrapet inte tar plats
-- i kvoten.
on varAttSpara(namn)
	set gemena to my gemener(namn)
	repeat with andelse in {".ics", ".vcf", ".p7s", ".asc", ".sig"}
		if gemena ends with (andelse as string) then return false
	end repeat
	-- Inbaddade signaturbilder heter image001.png och liknande
	if gemena starts with "image00" and (count of namn) <= 12 then return false
	return true
end varAttSpara

-- Snedstreck och kolon blir bindestreck, och ett namn som borjar med punkt
-- far ett understreck fore sig, sa att filen aldrig hamnar utanfor
-- bilagemappen eller blir dold.
on rensaNamn(t)
	set ut to ""
	repeat with c in characters of t
		set c to c as string
		if c is "/" or c is ":" then
			set ut to ut & "-"
		else
			set ut to ut & c
		end if
	end repeat
	if ut starts with "." then set ut to "_" & ut
	if ut is "" then set ut to "bilaga"
	return ut
end rensaNamn

on gemener(t)
	set ut to ""
	repeat with c in characters of t
		set c to c as string
		set i to offset of c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
		if i > 0 then
			set ut to ut & (character i of "abcdefghijklmnopqrstuvwxyz")
		else
			set ut to ut & c
		end if
	end repeat
	return ut
end gemener
