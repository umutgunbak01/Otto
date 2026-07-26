import SwiftUI
import AppKit

/// The Creative tab — an infinite node canvas over fal.ai's generative-media
/// catalog. Toolbar: workflow switcher · add node · run controls · zoom.
struct CreativeView: View {
    private var controller: CreativeCanvasController { .shared }

    @State private var showingRename = false
    @State private var renameDraft = ""
    @State private var showingDeleteConfirm = false
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            OttoDivider()

            ZStack(alignment: .topLeading) {
                CreativeCanvasView()

                if controller.showLibrary {
                    CreativeLibraryPanel()
                        .padding(Theme.Spacing.md)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(3)
                }

                if controller.bootstrapped && controller.workflow.nodes.isEmpty && !controller.showLibrary {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(true)
                }

                if let toast = controller.toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.text)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Theme.Colors.bg2)
                                    .overlay(Capsule().strokeBorder(Theme.Colors.borderStrong, lineWidth: 1))
                            )
                            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                            .padding(.bottom, Theme.Spacing.xl)
                    }
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(5)
                    .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: controller.showLibrary)
            .animation(.easeInOut(duration: 0.18), value: controller.toast != nil)
        }
        .background(Theme.Colors.bg0)
        .task { await controller.bootstrap() }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .alert("Rename workflow", isPresented: $showingRename) {
            TextField("Name", text: $renameDraft)
            Button("Rename") { controller.renameWorkflow(to: renameDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(controller.workflow.name)”?",
            isPresented: $showingDeleteConfirm
        ) {
            Button("Delete workflow", role: .destructive) {
                controller.deleteCurrentWorkflow()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nodes and their imported media are removed. Generated files on fal remain at their URLs.")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.Spacing.md) {
            workflowMenu

            Button {
                controller.showLibrary.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Add node")
                        .font(Theme.Typography.caption)
                }
            }
            .buttonStyle(AccentButtonStyle())
            .help("Browse fal.ai models and utilities")

            Spacer()

            runControls

            Spacer()

            arrangeButton
            zoomControls
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(height: 44)
        .background(Theme.Colors.bg1)
    }

    private var workflowMenu: some View {
        Menu {
            ForEach(controller.workflows) { workflow in
                Button {
                    controller.switchTo(workflowId: workflow.id)
                } label: {
                    if workflow.id == controller.workflow.id {
                        Label(workflow.name, systemImage: "checkmark")
                    } else {
                        Text(workflow.name)
                    }
                }
            }
            Divider()
            Button {
                controller.newWorkflow()
            } label: {
                Label("New workflow", systemImage: "plus")
            }
            Button {
                renameDraft = controller.workflow.name
                showingRename = true
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button {
                controller.duplicateWorkflow()
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Divider()
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                Label("Delete…", systemImage: "trash")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.textDim)
                // Cap the label width — agent-created workflows can carry
                // long names, and an uncapped Text inside .fixedSize() forces
                // the whole toolbar (and with it CreativeView's demanded
                // width) past the window, overflowing the canvas over the
                // sidebar and top bar.
                Text(controller.workflow.name)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 220)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.Colors.bg2)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var activeCount: Int {
        controller.runStates.values.filter(\.isActive).count
    }

    @ViewBuilder
    private var runControls: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if controller.anyNodeActive {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("\(activeCount) running")
                        .font(Theme.Typography.monoCaption)
                        .foregroundStyle(Theme.Colors.accentText)
                }
                Button {
                    controller.stop()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9))
                        Text("Stop")
                            .font(Theme.Typography.caption)
                    }
                    .foregroundStyle(Theme.Colors.red)
                }
                .buttonStyle(GhostButtonStyle())
            } else {
                if !controller.selectedNodeIds.isEmpty {
                    Button {
                        controller.runSelection()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                            Text("Run selected (\(controller.selectedNodeIds.count))")
                                .font(Theme.Typography.caption)
                        }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .help("Run the selected nodes as a sub-workflow (⌘↩) — un-run upstream nodes join automatically")

                    Button {
                        controller.runAll()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play")
                                .font(.system(size: 9))
                            Text("Run all")
                                .font(Theme.Typography.caption)
                        }
                        .foregroundStyle(Theme.Colors.textDim)
                    }
                    .buttonStyle(GhostButtonStyle())
                    .help("Run the whole graph in dependency order")
                } else {
                    Button {
                        controller.runAll()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                            Text("Run all")
                                .font(Theme.Typography.caption)
                        }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(controller.workflow.nodes.isEmpty)
                    .opacity(controller.workflow.nodes.isEmpty ? 0.5 : 1)
                    .help("Run the whole graph in dependency order (⌘↩)")
                }
            }
        }
    }

    private var arrangeButton: some View {
        Button {
            controller.autoArrange()
        } label: {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.Colors.textDim)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.bg2)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                )
        )
        .disabled(controller.workflow.nodes.isEmpty)
        .help("Auto-arrange nodes by dependency order")
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button {
                controller.zoomStep(-1)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textDim)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("Fit to content") { controller.fitToContent() }
                Divider()
                ForEach([50, 100, 150, 200], id: \.self) { percent in
                    Button("\(percent)%") { controller.setZoom(CGFloat(percent) / 100) }
                }
            } label: {
                Text("\(Int((controller.zoom * 100).rounded()))%")
                    .font(Theme.Typography.monoCaption)
                    .foregroundStyle(Theme.Colors.textDim)
                    .frame(width: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Button {
                controller.zoomStep(1)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textDim)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.bg2)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                )
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.Colors.tertiaryText)

            Text("Creative canvas")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.text)

            Text("Add fal.ai models to the canvas, wire outputs into inputs,\nand run single nodes or the whole graph.")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textDim)
                .multilineTextAlignment(.center)

            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    controller.showLibrary = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Browse models")
                            .font(Theme.Typography.caption)
                    }
                }
                .buttonStyle(AccentButtonStyle())

                Text("or drop an image, video, or audio file")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(.top, 2)

            if !FalAIService.shared.hasAPIKey() {
                HStack(spacing: 6) {
                    Image(systemName: "key")
                        .font(.system(size: 10))
                    Text("No fal.ai API key set — browsing works, running needs one.")
                        .font(Theme.Typography.caption)
                    Button("Open Settings") { showingSettings = true }
                        .buttonStyle(.plain)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.accentText)
                }
                .foregroundStyle(Theme.Colors.amber)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(Theme.Colors.tintAmber)
                )
                .padding(.top, Theme.Spacing.sm)
            }
        }
    }
}
