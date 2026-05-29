property gameTargets : {¬
	{aliasName:"Clone Hero.app", targetPath:"/Applications/Clone Hero.app"}, ¬
	{aliasName:"Factorio.app", targetPath:"/Applications/Factorio.app"}, ¬
	{aliasName:"League of Legends.app", targetPath:"/Applications/League of Legends.app"}, ¬
	{aliasName:"Prince of Persia Lost Crown.app", targetPath:"/Applications/Prince of Persia Lost Crown.app"}, ¬
	{aliasName:"Dota 2.app", targetPath:"/Users/martinsmith/Library/Application Support/Steam/steamapps/common/dota 2 beta/game/bin/osx64/dota2.app"}, ¬
	{aliasName:"Steam.app", targetPath:"/Applications/Steam.app"}, ¬
	{aliasName:"Epic Games Launcher.app", targetPath:"/Applications/Epic Games Launcher.app"}, ¬
	{aliasName:"Heroic.app", targetPath:"/Applications/Heroic.app"}, ¬
	{aliasName:"GameHub.app", targetPath:"/Applications/GameHub.app"}, ¬
	{aliasName:"Ryujinx.app", targetPath:"/Applications/Ryujinx.app"}, ¬
	{aliasName:"BlueStacksMIM.app", targetPath:"/Applications/BlueStacksMIM.app"}, ¬
	{aliasName:"Moonlight.app", targetPath:"/Applications/Moonlight.app"}, ¬
	{aliasName:"Controller.app", targetPath:"/Applications/Controller.app"} ¬
}

on run
	set gamesPath to "/Applications/Games"
	do shell script "mkdir -p " & quoted form of gamesPath
	set createdCount to 0
	set skippedCount to 0
	
	tell application "Finder"
		set gamesFolder to POSIX file gamesPath as alias
		repeat with gameTarget in gameTargets
			set targetPath to targetPath of gameTarget
			set aliasName to aliasName of gameTarget
			set aliasPath to gamesPath & "/" & aliasName
			set legacyAliasPath to aliasPath & " alias"
			
			try
				do shell script "test -e " & quoted form of targetPath
				try
					do shell script "test -e " & quoted form of aliasPath
					set skippedCount to skippedCount + 1
				on error
					try
						do shell script "test -e " & quoted form of legacyAliasPath
						set skippedCount to skippedCount + 1
					on error
						set newAlias to make new alias file at gamesFolder to (POSIX file targetPath as alias)
						set name of newAlias to aliasName
						set createdCount to createdCount + 1
					end try
				end try
			end try
		end repeat
	end tell
	
	display notification ((createdCount as text) & " aliases creados, " & (skippedCount as text) & " ya existian.") with title "Game Alias Builder"
end run
