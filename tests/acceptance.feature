Feature: Reliable offline-first Calisthenics workout
  As a user training with an iPhone
  I want to finish workouts without losing data or being misled by timers

  Background:
    Given the sample training plan "Planche Foundation / Pull / Legs" exists locally
    And the Tuck Planche preview poster is available offline

  @P0 @offline @player
  Scenario: A hold set does not complete itself when timer expires
    Given I started a 12 second Tuck Planche hold
    When 12 seconds elapsed
    And I have not confirmed a result
    Then the set is not marked completed
    And I can enter actual hold duration

  @P0 @offline @durability
  Scenario: Confirmed set survives app termination
    Given I confirmed actual hold 11 seconds for set 1
    When the app process is terminated immediately after local commit
    And the app is relaunched without internet
    Then exactly one completed set result exists locally
    And one corresponding outbox mutation is pending
    And the player can restore its next state

  @P0 @idempotency
  Scenario: Rapid double tap does not add an extra set
    Given I am confirming the result of set 1
    When the Confirm command with the same command ID runs twice
    Then exactly one result exists for set 1
    And no extra rest period is created

  @P0 @lockscreen @device
  Scenario: Lock Screen displays countdown without network
    Given notification and Live Activity permissions are enabled
    And the iPhone is offline
    And I am resting for 90 seconds
    When the iPhone auto-locks
    And I wake its screen 30 seconds later
    Then the Live Activity shows the current exercise and set
    And the countdown is based on the stored deadline
    And my workout session remains recoverable

  @P0 @lockscreen @security @device
  Scenario: Locked device does not bypass authentication for widget actions
    Given the iPhone is locked
    When I tap a Live Activity action
    Then the system requires authentication and unlock before executing it
    And no state mutation is assumed before a successful user action

  @P0 @rest
  Scenario: Rest extension supersedes old notification
    Given the rest deadline is 90 seconds from now
    When I add 30 seconds of rest
    Then the persisted rest deadline is 120 seconds from the original start
    And the previous rest reminder is canceled
    And a new reminder is scheduled

  @P0 @media
  Scenario: Missing video never blocks a workout
    Given the preview video is not downloaded
    When I open exercise details while offline
    Then I can see a correct cached or bundled poster
    And I can read technique cues
    And I can start or continue the workout

  @P0 @sync
  Scenario: Retry of the same mutation is idempotent
    Given a signed-in user has 1 locally confirmed set
    When the network retries the same mutation 10 times
    Then the server has 1 canonical set result
    And the server returns consistent applied or duplicate receipts

  @P0 @sync
  Scenario: Cursor is advanced only after local apply
    Given the server has a sync page of new workout notes
    When the app crashes after fetching but before committing the page
    And the app retries the same pull cursor
    Then the notes are applied without duplicates
    And the stored cursor advances atomically with the notes

  @P0 @ai
  Scenario: AI suggestion never modifies the plan without approval
    Given the AI analysis proposes a small increase in hold time
    When I view the analysis but do not accept the recommendation
    Then the active training plan is unchanged
    When I accept a valid recommendation against the current plan version
    Then a new plan revision is created
    And the previous plan remains accessible

  @P0 @ai @safety
  Scenario: A reported pain flag blocks escalation
    Given I reported wrist pain for a planche session
    When the coaching engine evaluates progression
    Then no automatic escalation recommendation is accepted
    And the UI does not present medical diagnosis

  @P0 @account
  Scenario: Local guest data is attached to signed-in profile without silent deletion
    Given I have workouts stored as guest
    When I sign in with Apple and choose to attach guest data
    Then the local workout IDs remain unchanged
    And the server receives them with deduplicated mutations
    And no guest workout is deleted before server acknowledgment
