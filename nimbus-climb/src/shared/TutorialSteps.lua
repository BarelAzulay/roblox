-- TutorialSteps: the new-player tutorial, told by Nimbus the Cloudy Dragon (ARCHITECTURE_V3.md section 4).
-- Data only: TutorialService (server) walks a player through these steps in order and TutorialController
-- (client) shows them in the side panel. Phases 2 and 3 append steps (home, arena) at the end.
--
-- Step fields
--   Id          unique step id (persisted progress is the step INDEX: Profile.Tutorial.Step)
--   Title       short headline shown above the text
--   Text        what Nimbus says (short, friendly). Placeholders filled in by TutorialService:
--               {GiftTokens} = Config.Tutorial.GiftTokens, {FinishTokens} = Config.Tutorial.FinishReward.Tokens
--   Target      nil, or where the guide arrow points:
--                 { Kind = "Spot" }                     the player's own home plot (SpotIndex attribute)
--                 { Kind = "Shop" }                     the roulette machines (Roulette_<first roulette id>)
--                 { Kind = "Roulette", Id = "Cloud" }   model Roulette_<Id> under workspace.NimbusLobby
--                 { Kind = "Portal", Id = "Easy" }      model Portal_<Id> under workspace.NimbusLobby
--                 { Kind = "Menu", Id = "Pets" }        the menu button MenuButton_<Id>
--               Label (optional) names the target on the floating sign above the arrow.
--   CompleteOn  "Next"         the player presses Next (client event)
--               "NearSpot"     within 14 studs of the player's own SpotInfo.Center (server poll)
--               "ShopOpened"   the Shop window opened (client event)
--               "Rolled"       a roulette spin succeeded (PetService.Rolled)
--               "Equipped"     the player equips a pet / opens Pets with a pet equipped
--               "IndexOpened"  the Pet Index window opened (client event)
--               "MatchStarted" the player's InMatch attribute turned true
--               "MatchEnded"   the player's InMatch attribute turned false again
--   Gift        true: entering this step grants Config.Tutorial.GiftTokens once (Profile.Tutorial.Gifted)
--   Hint        short objective line shown under the text while the step waits for an action
--   Button      label of the Next button (CompleteOn = "Next" only)
--
-- Plain Lua 5.1-compatible syntax only.

local TutorialSteps = {}

TutorialSteps.Guide = {
	Name = "Nimbus",
	Title = "the Cloudy Dragon",
	PetId = "cloudy_dragon", -- PetCatalog id of the portrait in the side panel
}

TutorialSteps.Steps = {
	{
		Id = "welcome",
		Title = "Hi there, climber!",
		Text = "I'm Nimbus, the Cloudy Dragon! Welcome to my sky village. Stick with me and I'll show you around. It's quick, promise!",
		Target = nil,
		CompleteOn = "Next",
		Button = "Let's go!",
	},
	{
		Id = "home",
		Title = "Your Home Plot",
		Text = "Every climber gets a home plot of their own! Follow my golden arrow there, or tap My Spot to whoosh right over.",
		Target = { Kind = "Spot", Label = "Your Home" },
		CompleteOn = "NearSpot",
		Hint = "Walk to your plot",
	},
	{
		Id = "shop",
		Title = "The Cloud Shop",
		Text = "Next stop: the Cloud Shop! Follow the arrow to the roulette machines and walk up to one. The Shop button works too.",
		Target = { Kind = "Shop", Label = "Cloud Shop" },
		CompleteOn = "ShopOpened",
		Hint = "Open the shop",
	},
	{
		Id = "spin",
		Title = "Your First Pet",
		Text = "Here are {GiftTokens} Cloud Tokens, my treat! Spin the Cloud Roulette to hatch your very first pet buddy.",
		Target = { Kind = "Roulette", Id = "Cloud", Label = "Cloud Roulette" },
		CompleteOn = "Rolled",
		Gift = true,
		Hint = "Spin a roulette",
	},
	{
		Id = "equip",
		Title = "Pick a Buddy",
		Text = "Aww, a new friend! Open Pets and equip your buddy so it flies right beside you. Pets give handy perks!",
		Target = { Kind = "Menu", Id = "Pets" },
		CompleteOn = "Equipped",
		Hint = "Tap the glowing Pets button",
	},
	{
		Id = "index",
		Title = "The Pet Index",
		Text = "Every pet you find lands in the Pet Index. Take a peek! Collect a whole rarity group for a big reward.",
		Target = { Kind = "Menu", Id = "Index" },
		CompleteOn = "IndexOpened",
		Hint = "Tap the glowing Index button",
	},
	{
		Id = "portal",
		Title = "Time to Climb!",
		Text = "Now the fun part! Step into the Easy portal and wait for the countdown. Friends can hop in with you.",
		Target = { Kind = "Portal", Id = "Easy", Label = "Easy Portal" },
		CompleteOn = "MatchStarted",
		Hint = "Stand in the Easy portal",
	},
	{
		Id = "finish",
		Title = "Up, Up and Away!",
		Text = "Hop from cloud to cloud, grab the shiny tokens and reach the finish. Checkpoints keep your progress. You've got this!",
		Target = nil,
		CompleteOn = "MatchEnded",
		Hint = "Reach the finish",
	},
	{
		Id = "done",
		Title = "You're a Natural!",
		Text = "That's the basics, climber! Here are {FinishTokens} Cloud Tokens to celebrate. See you up in the clouds!",
		Target = nil,
		CompleteOn = "Next",
		Button = "Collect!",
	},
}

-- Id -> index lookup (data, built once).
TutorialSteps.IndexOf = {}
for index, step in ipairs(TutorialSteps.Steps) do
	TutorialSteps.IndexOf[step.Id] = index
end

return TutorialSteps
