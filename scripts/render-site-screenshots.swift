import AppKit
import SwiftUI

@main
struct RenderApp {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
      await renderAll()
      exit(0)
    }
    app.run()
  }
}

@MainActor
func renderAll() async {
  let assets = NSString(string: "~/Documents/GitHub/afk/docs/site/assets").expandingTildeInPath

  func save<V: View>(_ view: V, size: CGSize, path: String, scale: CGFloat = 2) {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.scale = scale
    guard let img = renderer.nsImage,
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
      fputs("failed \(path)\n", stderr); return
    }
    let url = URL(fileURLWithPath: path)
    try? png.write(to: url)
    print("wrote \(path) \(png.count)")
  }

  struct ListeningPill: View {
    var body: some View {
      HStack(spacing: 10) {
        Circle().fill(Color.red).frame(width: 8, height: 8)
        HStack(spacing: 3) {
          ForEach(0..<9, id: \.self) { i in
            let heights: [CGFloat] = [6,10,16,20,22,18,12,8,5]
            Capsule().fill(Color.white).frame(width: 3, height: heights[i])
          }
        }.frame(height: 22)
        Text("hold Fn → speak → paste at the caret").lineLimit(1)
        Text("0:02").monospacedDigit().foregroundColor(.white.opacity(0.6))
      }
      .font(.system(size: 13, weight: .medium))
      .foregroundColor(.white)
      .padding(.horizontal, 16)
      .frame(height: 40)
      .background(Capsule().fill(Color.black.opacity(0.82)))
      .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
      .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  struct ListeningScene: View {
    var body: some View {
      ZStack {
        LinearGradient(colors: [Color(red:0.12,green:0.12,blue:0.16), Color(red:0.08,green:0.09,blue:0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
        VStack { Spacer(); ListeningPill(); Spacer().frame(height: 48) }
      }
    }
  }

  struct SettingsMock: View {
    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        group("Speech-to-text") {
          row("Provider", value: "xAI Grok (default)")
          modelRow("grok-voice-transcribe-2.0")
          Text("Streams while you talk (live text in the pill).").font(.caption).foregroundColor(.secondary)
        }
        group("Polish") {
          row("Provider", value: "xAI Grok (default)")
          modelRow("grok-4-1-fast-non-reasoning")
        }
        group("API Keys") {
          keyRow("xAI Grok", status: "Saved on this Mac")
          keyRow("OpenRouter", status: "Not set")
          keyRow("OpenAI", status: "Not set")
          keyRow("Custom", status: "Optional")
        }
        Spacer(minLength: 0)
        HStack {
          Text("Keys are saved only on this Mac, readable by your user.").font(.caption).foregroundColor(.secondary)
          Spacer()
          Text("Cancel").padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
          Text("Save").fontWeight(.semibold).foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor))
        }
      }
      .padding(16)
      .frame(width: 560, height: 520, alignment: .topLeading)
      .background(Color(nsColor: .windowBackgroundColor))
    }
    func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
      VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.headline)
        VStack(alignment: .leading, spacing: 6) { content() }
          .padding(8).frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
      }
    }
    func row(_ label: String, value: String) -> some View {
      HStack {
        Text(label).frame(width: 72, alignment: .leading)
        Text(value).font(.system(size: 12, design: .monospaced))
          .padding(.horizontal, 8).padding(.vertical, 4)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
      }
    }
    func modelRow(_ value: String) -> some View {
      HStack(spacing: 8) {
        Text("Model").frame(width: 72, alignment: .leading)
        Text(value).font(.system(size: 12, design: .monospaced))
          .padding(.horizontal, 8).padding(.vertical, 4)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
        Text("Default").font(.system(size: 12))
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
      }
    }

    func keyRow(_ name: String, status: String) -> some View {
      HStack(alignment: .firstTextBaseline) {
        Text(name).frame(width: 80, alignment: .leading)
        VStack(alignment: .leading, spacing: 2) {
          Text("••••••••••••").font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
          Text(status).font(.caption2).foregroundColor(.secondary)
        }
      }
    }
  }

  struct SettingsWindowChrome: View {
    var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: 7) {
          Circle().fill(Color(red:1,green:0.38,blue:0.35)).frame(width: 12, height: 12)
          Circle().fill(Color(red:1,green:0.74,blue:0.25)).frame(width: 12, height: 12)
          Circle().fill(Color(red:0.15,green:0.79,blue:0.35)).frame(width: 12, height: 12)
          Spacer()
          Text("AFK Settings").font(.system(size: 13, weight: .medium))
          Spacer()
          Color.clear.frame(width: 50)
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(Color(nsColor: .windowBackgroundColor))
        SettingsMock()
      }
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.25), lineWidth: 1))
      .shadow(color: .black.opacity(0.45), radius: 28, y: 14)
      .padding(36)
      .frame(width: 640, height: 620)
      .background(LinearGradient(colors: [Color(red:0.10,green:0.11,blue:0.15), Color(red:0.06,green:0.07,blue:0.10)], startPoint: .top, endPoint: .bottom))
    }
  }

  struct HeroCard: View {
    var body: some View {
      ZStack {
        LinearGradient(colors: [Color(red:0.09,green:0.10,blue:0.14), Color(red:0.05,green:0.06,blue:0.09)], startPoint: .topLeading, endPoint: .bottomTrailing)
        VStack(spacing: 28) {
          HStack(spacing: 14) {
            ZStack {
              RoundedRectangle(cornerRadius: 22).fill(Color.black)
              VStack(spacing: 10) {
                HStack(spacing: 18) {
                  Circle().fill(Color.white).frame(width: 10, height: 10)
                  Circle().fill(Color.white).frame(width: 10, height: 10)
                }
                HStack(alignment: .bottom, spacing: 5) {
                  Capsule().fill(Color.white).frame(width: 7, height: 12)
                  Capsule().fill(Color.white).frame(width: 7, height: 18)
                  Capsule().fill(Color.white).frame(width: 7, height: 22)
                  Capsule().fill(Color.white).frame(width: 7, height: 18)
                  Capsule().fill(Color.white).frame(width: 7, height: 12)
                }
              }
            }.frame(width: 72, height: 72)
            Text("AFK").font(.system(size: 56, weight: .bold)).tracking(2).foregroundColor(.white)
          }
          Text("Away From Keyboard").font(.system(size: 18, weight: .medium)).foregroundColor(.white.opacity(0.55))
          ListeningPill().padding(.top, 8)
        }
      }
    }
  }

  save(ListeningPill().frame(width: 560, height: 96), size: CGSize(width: 560, height: 96), path: "\(assets)/screenshot-listening-pill.png")
  save(ListeningScene(), size: CGSize(width: 960, height: 420), path: "\(assets)/screenshot-listening.png")
  save(SettingsWindowChrome(), size: CGSize(width: 640, height: 620), path: "\(assets)/screenshot-settings.png")
  save(HeroCard(), size: CGSize(width: 1200, height: 630), path: "\(assets)/og-image.png")
  save(HeroCard(), size: CGSize(width: 1100, height: 640), path: "\(assets)/screenshot-hero.png")
}
