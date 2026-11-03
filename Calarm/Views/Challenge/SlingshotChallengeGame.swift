//
//  SlingshotChallengeGame.swift
//  Calarm
//

import SpriteKit
import SwiftUI

/// «Tirachinas»: la escena de SpriteKit (`SlingshotScene`) dentro del marco de
/// los retos, con el progreso arriba y los tiros que quedan en una esquina.
struct SlingshotChallengeGame: View {
    let difficulty: WakeChallenge.Difficulty
    let onSolved: () -> Void

    @State private var hud: SlingshotHUD
    @State private var scene: SlingshotScene
    @State private var reported = false
    @Environment(\.colorScheme) private var colorScheme

    init(difficulty: WakeChallenge.Difficulty, onSolved: @escaping () -> Void) {
        self.difficulty = difficulty
        self.onSolved = onSolved
        let config = SlingshotScene.Config(difficulty: difficulty)
        let hud = SlingshotHUD(required: config.required, shotsPerLevel: config.shots)
        _hud = State(initialValue: hud)
        _scene = State(initialValue: SlingshotScene(config: config, hud: hud))
    }

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            ArcadeProgressHeader(
                label: appLocalized("Derribados \(hud.knocked) de \(hud.required)"),
                value: hud.knocked,
                total: hud.required
            )
            SpriteView(scene: scene, preferredFramesPerSecond: 60, options: [.allowsTransparency])
                .background(sky)
                .arcadeArena(aspectRatio: SlingshotScene.sceneSize.width / SlingshotScene.sceneSize.height)
                .overlay(alignment: .bottomTrailing) { shots }
                .overlay(alignment: .top) { banner }
                .animation(DS.Motion.quick, value: hud.message)
        }
        .onChange(of: hud.knocked) { old, new in
            guard new > old else { return }
            Haptics.light()
            if new >= hud.required, !reported {
                reported = true
                onSolved()
            }
        }
    }

    private var sky: LinearGradient {
        let colors = colorScheme == .dark
            ? [Color(red: 0.06, green: 0.10, blue: 0.20), Color(red: 0.17, green: 0.20, blue: 0.33)]
            : [Color(red: 0.62, green: 0.83, blue: 0.98), Color(red: 0.95, green: 0.97, blue: 1.00)]
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    /// Una bolita por tiro, sobre la franja de hierba; las gastadas quedan huecas.
    private var shots: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(0..<hud.shotsPerLevel, id: \.self) { index in
                Circle()
                    .fill(index < hud.shotsLeft ? Color.white : Color.clear)
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                    .frame(width: 10, height: 10)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, 9)
        .animation(DS.Motion.quick, value: hud.shotsLeft)
        .accessibilityElement()
        .accessibilityLabel(Text(appLocalized("Tiros: \(hud.shotsLeft)")))
    }

    @ViewBuilder
    private var banner: some View {
        switch hud.message {
        case .aim:
            ArcadeBanner("Estira hacia atrás desde la izquierda y suelta")
        case .cleared:
            ArcadeBanner("¡Torre despejada!")
        case .outOfShots:
            ArcadeBanner("Sin tiros: torre nueva")
        case nil:
            EmptyView()
        }
    }
}
