import SwiftUI

struct MessageListView: View {
  let messages: [Message]

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(messages, id: \.id) { message in
            HStack(alignment: .top, spacing: 8) {
              if message.role == .user {
                Spacer()
              }

              VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                Text(message.role == .user ? "You" : "Chime")
                  .font(.caption2.bold())
                  .foregroundStyle(.secondary)
                Text(message.content)
                  .font(.caption)
                  .lineLimit(nil)
                  .fixedSize(horizontal: false, vertical: true)

                if let metadata = message.metadata, let citations = metadata.citations, !citations.isEmpty {
                  Text("via: \(citations[0].title)")
                    .font(.caption2)
                    .foregroundColor(.blue)
                }
              }
              .padding(8)
              .background(message.role == .user ? Color.teal.opacity(0.3) : Color.white.opacity(0.08))
              .cornerRadius(8)

              if message.role == .assistant {
                Spacer()
              }
            }
            .id(message.id)
          }
        }
        .padding(8)
        .onChange(of: messages.last?.content) { _, _ in
          if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
        .onAppear {
          if let last = messages.last {
            proxy.scrollTo(last.id)
          }
        }
      }
    }
  }
}
