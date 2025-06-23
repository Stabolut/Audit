import plotly.graph_objects as go
import numpy as np

# Define colors based on instructions
colors = {
    'core': '#1FB8CD',      # Blue for core protocol contracts
    'external': '#ECEBD5',  # Light green for external integrations  
    'user': '#FFC185',      # Orange for user interactions
    'emergency': '#B4413C'  # Red for emergency systems
}

# Define positions for components with clearer flow structure
positions = {
    # Core contracts in center
    'StabolutEngine': (0, 0),
    'USBStablecoin': (-1.5, 0),
    'SBLGovernToken': (1.5, 0),
    'StakingContract': (0, -1.5),
    'Treasury': (1.5, -1.5),
    
    # External components around edges
    'Users': (-3, 1),
    'Chainlink': (0, 2),
    'DeltaNeutral': (3, 1),
    'Governance': (-3, -1.5),
    'Emergency': (3, -2.5)
}

# Create the figure
fig = go.Figure()

# Function to add a component box
def add_component(name, pos, color, width=1.2, height=0.8):
    x, y = pos
    fig.add_shape(
        type="rect",
        x0=x-width/2, y0=y-height/2,
        x1=x+width/2, y1=y+height/2,
        fillcolor=color,
        line=dict(color="black", width=1),
        opacity=0.8
    )
    
    # Add text label
    fig.add_annotation(
        x=x, y=y,
        text=name,
        showarrow=False,
        font=dict(size=12, color="black"),
        xanchor="center",
        yanchor="middle"
    )

# Add components
# Core protocol contracts (blue)
add_component("StabolutEngine", positions['StabolutEngine'], colors['core'])
add_component("USBStablecoin", positions['USBStablecoin'], colors['core'])
add_component("SBLGovernToken", positions['SBLGovernToken'], colors['core'])
add_component("StakingContract", positions['StakingContract'], colors['core'])
add_component("Treasury", positions['Treasury'], colors['core'])

# External integrations (green)
add_component("Chainlink Feeds", positions['Chainlink'], colors['external'])
add_component("DeltaNeutral", positions['DeltaNeutral'], colors['external'])
add_component("Governance", positions['Governance'], colors['external'])

# User interactions (orange)
add_component("Users", positions['Users'], colors['user'])

# Emergency systems (red)
add_component("Emergency Ctrl", positions['Emergency'], colors['emergency'])

# Function to add visible arrows between components
def add_arrow(start, end, text=None, curve=0, color="black"):
    x0, y0 = positions[start]
    x1, y1 = positions[end]
    
    # Calculate distance for adjusting start/end points
    dx = x1 - x0
    dy = y1 - y0
    dist = np.sqrt(dx*dx + dy*dy)
    
    # Adjust to prevent arrows from crossing the boxes
    box_scale = 0.6
    x0_adj = x0 + (dx/dist)*box_scale
    y0_adj = y0 + (dy/dist)*box_scale
    x1_adj = x1 - (dx/dist)*box_scale
    y1_adj = y1 - (dy/dist)*box_scale
    
    # Add the arrow
    fig.add_shape(
        type="path",
        path=f"M {x0_adj},{y0_adj} Q {(x0_adj+x1_adj)/2+curve},{(y0_adj+y1_adj)/2} {x1_adj},{y1_adj}",
        line=dict(color=color, width=2),
        line_dash="solid"
    )
    
    # Add arrowhead
    angle = np.arctan2(y1_adj - ((y0_adj+y1_adj)/2+curve*0.5), 
                      x1_adj - ((x0_adj+x1_adj)/2+curve*0.5))
    
    ax = x1_adj - 0.15 * np.cos(angle)
    ay = y1_adj - 0.15 * np.sin(angle)
    
    fig.add_annotation(
        x=x1_adj, y=y1_adj,
        ax=ax, ay=ay,
        xref="x", yref="y",
        axref="x", ayref="y",
        showarrow=True,
        arrowhead=3,
        arrowsize=1.5,
        arrowwidth=2,
        arrowcolor=color
    )
    
    # Add arrow label if provided
    if text:
        fig.add_annotation(
            x=(x0_adj+x1_adj)/2 + curve*0.8,
            y=(y0_adj+y1_adj)/2,
            text=text,
            showarrow=False,
            font=dict(size=10, color="black"),
            bgcolor="white",
            bordercolor="black",
            borderwidth=1,
            xanchor="center"
        )

# Add flow arrows with labels
add_arrow('Users', 'StabolutEngine', "Deposit Crypto")
add_arrow('StabolutEngine', 'DeltaNeutral', "Deploy Assets")
add_arrow('DeltaNeutral', 'StabolutEngine', "Generate Yield", curve=0.4)
add_arrow('StabolutEngine', 'USBStablecoin', "Mint USB")
add_arrow('USBStablecoin', 'StakingContract', "Stake USB")
add_arrow('StakingContract', 'SBLGovernToken', "Earn SBL")
add_arrow('DeltaNeutral', 'Treasury', "Profits", curve=0.2)
add_arrow('Chainlink', 'StabolutEngine', "Price Data")
add_arrow('Governance', 'StabolutEngine', "Set Params")
add_arrow('Emergency', 'StabolutEngine', "Pause/Resume")

# Add key features with connecting arrows to relevant components
def add_feature_label(x, y, text, conn_x, conn_y):
    fig.add_annotation(
        x=x, y=y,
        text=text,
        showarrow=False,
        font=dict(size=10, color="black"),
        bgcolor="white",
        bordercolor="black",
        borderwidth=1,
        xanchor="center"
    )
    
    # Add connecting line to component
    fig.add_shape(
        type="line",
        x0=x, y0=y,
        x1=conn_x, y1=conn_y,
        line=dict(color="black", width=1, dash="dot")
    )

# Add feature labels connected to relevant components
add_feature_label(-2, 2, "150% Collat Ratio", -0.2, 0.4)  # Connected to Engine
add_feature_label(2, 2, "Circuit Breakers", 0.2, 0.4)     # Connected to Engine
add_feature_label(-2, -2.5, "Timelock Mechs", -3, -1.8)   # Connected to Governance
add_feature_label(2, -3, "Multi-sig Ctrl", 3, -2.7)       # Connected to Emergency

# Set axis ranges with some padding
x_values = [pos[0] for pos in positions.values()]
y_values = [pos[1] for pos in positions.values()]
x_range = [min(x_values) - 1.5, max(x_values) + 1.5]
y_range = [min(y_values) - 1.5, max(y_values) + 1.5]

# Update layout
fig.update_layout(
    title="Stabolut Protocol Architecture",
    plot_bgcolor='white',
    showlegend=False,
)

# Update axes
fig.update_xaxes(
    showgrid=False,
    showticklabels=False,
    zeroline=False,
    range=x_range
)
fig.update_yaxes(
    showgrid=False,
    showticklabels=False,
    zeroline=False,
    range=y_range
)

# Add color legend for the different component types
legend_x = x_range[0] + 0.5
legend_y_start = y_range[1] - 0.5
legend_spacing = 0.5

legend_items = [
    ("Core Protocol", colors['core']),
    ("External", colors['external']),
    ("User", colors['user']),
    ("Emergency", colors['emergency'])
]

for i, (label, color) in enumerate(legend_items):
    y_pos = legend_y_start - i * legend_spacing
    
    # Add colored box
    fig.add_shape(
        type="rect",
        x0=legend_x, y0=y_pos-0.2,
        x1=legend_x+0.4, y1=y_pos+0.2,
        fillcolor=color,
        line=dict(color="black", width=1)
    )
    
    # Add label
    fig.add_annotation(
        x=legend_x+0.7, y=y_pos,
        text=label,
        showarrow=False,
        font=dict(size=10),
        xanchor="left"
    )

# Save the chart
fig.write_image("stabolut_architecture.png")
fig.show()